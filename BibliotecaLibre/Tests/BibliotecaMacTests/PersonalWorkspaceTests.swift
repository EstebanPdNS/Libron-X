import Foundation
import Testing
@testable import LibronixCore
@testable import BibliotecaMac

@MainActor @Suite struct PersonalWorkspaceTests {
    @Test func favoritesUndoRedoAndNumberedBookmarksSurviveAStoreReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = PersonalLibraryStore(directory: root)
        let folder = LibraryFavorite(title: "My study", kind: .folder)
        let location = ReaderLocation(resourceID: "/own/book.LSF", format: .legacyLSF, sectionOrdinal: 0)
        let favorite = LibraryFavorite(parentID: folder.id, title: "Test position", kind: .location, location: location)
        personal.change { try $0.insert(folder); try $0.insert(favorite) }
        personal.change { try $0.rename(favorite.id, title: "Renamed") }
        #expect(personal.canUndo && !personal.canRedo)
        personal.undo(); #expect(personal.favorites.items.last?.title == "Test position")
        personal.redo(); #expect(personal.favorites.items.last?.title == "Renamed")
        personal.setBookmark(9, location: location)
        let reopened = PersonalLibraryStore(directory: root)
        #expect(reopened.errorMessage == nil && reopened.favorites == personal.favorites)
        #expect(reopened.bookmarks.slots[9] == location)
        reopened.setBookmark(9, location: nil)
        #expect(PersonalLibraryStore(directory: root).bookmarks.slots[9] == nil)
        #expect(reopened.favorites == personal.favorites)
    }
    @Test func aFutureFavoritesFileIsPreservedInsteadOfOverwrittenWithEmptyState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("favorites.json"), data = Data(#"{"schemaVersion":2,"items":[]}"#.utf8)
        try data.write(to: url)
        let store = PersonalLibraryStore(directory: root)
        #expect(store.errorMessage != nil)
        store.change { try $0.insert(LibraryFavorite(title: "New", kind: .folder)) }
        #expect(try Data(contentsOf: url) == data)
    }
    @Test func linkedReadersAlignOnJoinPropagateBothWaysAndDetachWithoutFeedback() async throws {
        let fixture = try LinkedReaderFixture(); defer { fixture.remove() }
        let store = fixture.store()
        let first = LibraryModel(store: store), second = LibraryModel(store: store), independent = LibraryModel(store: store)
        for (model, index) in [(first, 0), (second, 1), (independent, 0)] {
            model.selection = fixture.resources[index].id; model.reader.open(fixture.resources[index])
            try await settle(model.reader)
        }
        first.reader.navigateToReference("John 1:1"); try await settle(first.reader)
        first.linkGroup = .a; second.linkGroup = .a; try await settle(second.reader)
        #expect(second.reader.committedReference == "John 1:1")
        first.reader.navigateToReference("John 3:16"); try await settle(first.reader); try await settle(second.reader)
        #expect(first.reader.ordinal == 1 && second.reader.ordinal == 1)
        #expect(first.reader.content?.plainText == "Edition A · John3")
        #expect(second.reader.content?.plainText == "Edition B · John3")
        #expect(independent.reader.ordinal == 0)
        second.reader.navigateToReference("Genesis 1:1"); try await settle(second.reader); try await settle(first.reader)
        #expect(first.reader.ordinal == 2 && first.reader.committedReference == "Genesis 1:1")
        let visits = second.reader.history.sections
        second.linkGroup = .none
        first.reader.navigateToReference("Psalm 23:1"); try await settle(first.reader)
        #expect(second.reader.ordinal == 2 && second.reader.history.sections == visits)
        second.linkGroup = .a; try await settle(second.reader)
        #expect(second.reader.ordinal == 3 && second.reader.committedReference == "Psalm 23:1")
        store.clearLinks(); #expect(first.linkGroup == .none && second.linkGroup == .none)
        #expect(second.reader.history.sections.count < 10)
        for model in [first, second, independent] { model.reader.cancelPendingRead() }
    }
    @Test func aFailedLinkedReferencePreservesTheOtherReadersLastCommittedDestination() async throws {
        let fixture = try LinkedReaderFixture(); defer { fixture.remove() }
        let store = fixture.store()
        let first = LibraryModel(store: store)
        let second = LibraryModel(store: store)
        first.selection = fixture.resources[0].id; first.reader.open(fixture.resources[0]); try await settle(first.reader)
        second.selection = fixture.resources[1].id; second.reader.open(fixture.resources[1]); try await settle(second.reader)
        first.linkGroup = .a; second.linkGroup = .a
        second.reader.navigateToReference("John 99:1"); try await settle(second.reader)
        #expect(second.reader.ordinal == 0 && second.reader.committedReference == nil)
        #expect(second.reader.navigationMessage != nil && first.reader.ordinal == 0)
    }
    @Test func restoringWorkspaceLoadsContentAndHistoryWithoutDiscardingSearchOrCatalogState() async throws {
        let fixture = try LinkedReaderFixture(); defer { fixture.remove() }
        let store = fixture.store(), original = LibraryModel(store: fixture.store())
        original.selection = fixture.resources[0].id; original.reader.open(fixture.resources[0]); try await settle(original.reader)
        original.reader.load(2); try await settle(original.reader)
        original.reader.load(3); try await settle(original.reader)
        original.reader.goBack(); try await settle(original.reader)
        original.section = .search; original.searchText = "Edition"; original.sort = .author
        original.bookSearch.queryText = "\"Own phrase\""; original.bookSearch.unit = .bibleVerse
        original.bookSearch.caseSensitive = true; original.linkGroup = .a
        let state = original.workspaceState()
        let restored = LibraryModel(store: store); restored.restore(state); try await settle(restored.reader)
        #expect(restored.reader.content?.plainText == "Edition A · Genesis1")
        #expect(restored.reader.history == original.reader.history && restored.reader.canGoForward)
        #expect(restored.section == .search && restored.searchText == "Edition" && restored.sort == .author)
        #expect(restored.bookSearch.queryText == "\"Own phrase\"" && restored.bookSearch.unit == .bibleVerse && restored.bookSearch.caseSensitive)
        #expect(restored.linkGroup == .a)
        restored.reader.goForward(); try await settle(restored.reader)
        #expect(restored.reader.ordinal == 3)
    }
    @Test func missingWorkspaceResourcesRemainRecoverableAndChangedTextCannotBeOpenedByAnOldFavorite() async throws {
        let fixture = try LinkedReaderFixture(); defer { fixture.remove() }
        let store = fixture.store(), original = LibraryModel(store: store)
        original.selection = fixture.resources[0].id; original.reader.open(fixture.resources[0]); try await settle(original.reader)
        original.reader.load(1); try await settle(original.reader)
        let state = original.workspaceState(), target = try #require(state.location)
        let missingStore = LibraryStore(personalDirectory: fixture.root.appendingPathComponent("missing"))
        missingStore.snapshot = LibrarySnapshot(root: fixture.root, resources: [], discoveredFiles: 0, importDurationSeconds: 0)
        let restored = LibraryModel(store: missingStore); restored.restore(state)
        #expect(restored.destinationError != nil && restored.reader.content == nil)
        #expect(restored.workspaceState().location == target)
        missingStore.snapshot = store.snapshot; restored.reconcileSelection(); try await settle(restored.reader)
        #expect(restored.reader.ordinal == 1 && restored.reader.content != nil)
        let before = restored.reader.content
        var wrongFingerprint = target; wrongFingerprint.textFingerprint = "different-edition-text"
        restored.navigate(wrongFingerprint); try await settle(restored.reader)
        #expect(restored.reader.content == before && restored.reader.errorMessage != nil)
    }
    private func settle(_ reader: ResourceReaderModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reader.isLoading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(!reader.isLoading, "Synthetic navigation exceeded five seconds")
    }
}

struct LinkedReaderFixture {
    let root: URL
    let resources: [LibraryResource]
    @MainActor func store() -> LibraryStore {
        let store = LibraryStore(personalDirectory: root.appendingPathComponent("personal"))
        store.snapshot = LibrarySnapshot(root: root, resources: resources, discoveredFiles: resources.count, importDurationSeconds: 0)
        return store
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("libronx-links-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let refs = ["Jn 1:1", "Jn 3:16", "Ge 1:1", "Ps 23:1"], labels = ["John1", "John3", "Genesis1", "Psalm23"]
        var resources: [LibraryResource] = []
        for edition in ["A", "B"] {
            let identifier = Data([1,0,0,0,edition == "A" ? 3 : 4,0,0,0,53,0]), url = root.appendingPathComponent(edition + ".LSF")
            let lix = root.appendingPathComponent(edition + ".LIX")
            var tart = Data(), hits = Data(), titles = Data(), counts = Data(), cumulative: UInt32 = 0
            for i in refs.indices {
                let offset = tart.count, text = "Edition \(edition) · \(labels[i])", units = Array(text.utf16)
                var doc = Data(repeating: 0, count: 36)
                Self.put16(17, &doc, 4); Self.put32(1, &doc, 6); Self.put16(1, &doc, 10); Self.put16(1, &doc, 12)
                Self.put32(UInt32(units.count), &doc, 16); Self.put16(1, &doc, 20); Self.put16(1, &doc, 22); Self.put16(2, &doc, 24)
                Self.put32(10_000, &doc, 26); Self.put32(UInt32(units.count + 1), &doc, 32)
                doc.append(Self.le16(81) + Self.le16(128) + Self.le16(2) + Self.le16(UInt16(refs[i].utf8.count)) + Data(refs[i].utf8))
                doc.append(Self.le16(17) + Self.le16(0) + Self.le16(0) + Self.le16(UInt16(units.count)) + Self.le16(1033) + Data([0xf0]))
                for unit in units { doc.append(Self.le16(unit)) }; doc.append(Self.le16(0)); Self.put32(UInt32(doc.count), &doc, 0)
                tart.append(Self.le16(0) + Self.le32(UInt32(doc.count)) + doc)
                cumulative += UInt32(units.count); counts.append(Self.le32(cumulative))
                hits.append(Self.le32(UInt32(i)) + Self.le32(UInt32(offset)) + Self.le32(UInt32(titles.count)) + Self.le32(0x80000000) + Self.le32(UInt32(i)) + Data([1]))
                let title = Array("Own article \(i)".utf16); titles.append(Self.le16(UInt16(title.count)))
                for unit in title { titles.append(Self.le16(unit)) }; titles.append(Self.le16(0))
            }
            let lsfData = Self.container("GTTL", chunks: [.init("bkid", identifier), .init("tart", tart)])
            try lsfData.write(to: url)
            let aidx = Chunk("AIDX", children: [.init("info", Self.le16(0) + Self.le32(4) + Self.le32(4) + Self.le16(1)), .init("klst", titles), .init("hlst", hits)])
            try Self.container("BIDX", chunks: [.init("bkid", Self.le16(1) + identifier), aidx, .init("ccct", counts)]).write(to: lix)
            resources.append(LibraryResource(location: url, indexLocation: lix, title: "Edition \(edition)", byteCount: Int64(lsfData.count),
                format: .legacyLSF, support: .metadataOnly, provenance: .fileName, legacyIdentifier: identifier.map { String(format:"%02x",$0) }.joined()))
        }
        self.resources = resources
    }
    func remove() {
        for resource in resources { UserDefaults.standard.removeObject(forKey: "readerPosition.v1." + resource.id) }
        try? FileManager.default.removeItem(at: root)
    }
    private struct Chunk {
        let tag: String; let data: Data; let children: [Chunk]
        init(_ tag: String, _ data: Data = Data(), children: [Chunk] = []) { self.tag = tag; self.data = data; self.children = children }
        var payloadSize: Int { children.isEmpty ? data.count : children.reduce(0) { $0 + 8 + $1.payloadSize } }
        var entryCount: Int { 1 + children.reduce(0) { $0 + $1.entryCount } }
    }
    private static func container(_ kind: String, chunks: [Chunk]) -> Data {
        let size = 18 + chunks.reduce(0) { $0 + $1.entryCount } * 18
        var header = Data(repeating: 0, count: 44), directory = Data(repeating: 0, count: 18), payload = Data()
        header.replaceSubrange(0..<4, with: Data("LSFF".utf8)); header.replaceSubrange(8..<12, with: Data(kind.utf8))
        header.replaceSubrange(36..<40, with: Data("pcr ".utf8)); put32(UInt32(size), &header, 40)
        directory.replaceSubrange(0..<4, with: Data("LSFF".utf8)); directory.replaceSubrange(4..<8, with: Data(kind.utf8))
        func emit(_ chunk: Chunk, at offset: Int) -> Data {
            directory.append(Data(chunk.tag.utf8) + le32(0) + le32(UInt32(chunk.payloadSize)) + le32(UInt32(offset + 8)) + le16(UInt16(chunk.children.count)))
            var bytes = Data(chunk.tag.utf8) + le32(UInt32(chunk.payloadSize))
            if chunk.children.isEmpty { bytes.append(chunk.data) }
            else { for child in chunk.children { bytes.append(emit(child, at: offset + bytes.count)) } }
            return bytes
        }
        for chunk in chunks { payload.append(emit(chunk, at: 44 + size + payload.count)) }
        var result = header + directory + payload; put32(UInt32(result.count - 8), &result, 4); return result
    }
    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 255), UInt8(value >> 8)]) }
    private static func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
    private static func put16(_ value: UInt16, _ data: inout Data, _ at: Int) { data.replaceSubrange(at..<(at + 2), with: le16(value)) }
    private static func put32(_ value: UInt32, _ data: inout Data, _ at: Int) { data.replaceSubrange(at..<(at + 4), with: le32(value)) }
}
