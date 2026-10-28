import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct QuickBookmarkTests {
    @Test func bookmarksSaveReopenAndNavigateToTheVerifiedPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: personal)
        let resource = LibraryResource(location: root.appendingPathComponent("owned.LSF"), title: "Owned",
            byteCount: 0, format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        workspace.resources = [resource]
        let original = workspace.open(resource, startReading: false)
        let text = "😀 Alpha beta"
        original.page = ReaderPage(destination: .init(ordinal: 2), text: text, sectionCount: 3)
        original.viewportCharacterOffset = 3
        workspace.assignBookmark(9)
        let stored = try #require(personal.bookmarks.slots[9])
        #expect(stored.resourceID == resource.id && stored.characterOffset == 3)
        #expect(stored.textFingerprint == LibrarySearchService.textFingerprint(text))
        let reopened = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        #expect(reopened.bookmarks.slots[9] == stored)
        let second = StudyWorkspace(personal: reopened); second.resources = [resource]
        second.openBookmark(9, loader: { _, destination in ReaderPage(destination: destination, text: text, sectionCount: 3) })
        let target = try #require(second.activeReader)
        for _ in 0..<100 where target.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!target.isLoading && target.error == nil && target.selectedRange == NSRange(location: 3, length: 0))
        #expect(target.page?.destination.ordinal == 2)
        second.removeBookmark(9)
        #expect(WorkspacePersonalState(url: root.appendingPathComponent("personal.json")).bookmarks.slots[9] == nil)
    }

    @Test func missingOrChangedResourcesDoNotSilentlyNavigateToDifferentText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        let resource = LibraryResource(location: root.appendingPathComponent("owned.LSF"), title: "Owned",
            byteCount: 0, format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        let location = ReaderLocation(resourceID: resource.id, format: resource.format, sectionOrdinal: 0,
            textFingerprint: LibrarySearchService.textFingerprint("original"), characterOffset: 3)
        try personal.setBookmark(1, location: location)
        let workspace = StudyWorkspace(personal: personal)
        workspace.openBookmark(1)
        #expect(workspace.readers.isEmpty && workspace.error != nil)
        workspace.resources = [resource]; workspace.error = nil
        workspace.openBookmark(1, loader: { _, destination in ReaderPage(destination: destination, text: "changed", sectionCount: 1) })
        let reader = try #require(workspace.activeReader)
        for _ in 0..<100 where reader.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!reader.isLoading && reader.error != nil && reader.page == nil)
        #expect(personal.bookmarks.slots[1] == location)
    }

    @Test func favoritesRestoreExactPositionAndRejectChangedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resource = LibraryResource(location: root.appendingPathComponent("owned.LSF"), title: "Owned", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        let text = "😀 Alpha beta", location = ReaderLocation(resourceID: resource.id, format: resource.format, sectionOrdinal: 1,
            textFingerprint: LibrarySearchService.textFingerprint(text), characterOffset: 3)
        let favorite = LibraryFavorite(title: "Owned", kind: .location, location: location)
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: root.appendingPathComponent("personal.json")))
        workspace.resources = [resource]
        workspace.openFavorite(favorite, loader: { _, destination in ReaderPage(destination: destination, text: text, sectionCount: 2) })
        let first = try #require(workspace.activeReader)
        for _ in 0..<100 where first.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(first.error == nil && first.page?.destination.ordinal == 1 && first.selectedRange == NSRange(location: 3, length: 0))
        workspace.openFavorite(favorite, loader: { _, destination in ReaderPage(destination: destination, text: "different", sectionCount: 2) })
        let second = try #require(workspace.activeReader)
        for _ in 0..<100 where second.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(second.error != nil && second.page == nil && favorite.location == location)
    }

    @Test func favoriteEditsAreAtomicWhenPersonalStateChangesExternally() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json")
        let first = WorkspacePersonalState(url: url), second = WorkspacePersonalState(url: url)
        let folder = LibraryFavorite(title: "Own", kind: .folder)
        try first.editFavorites { try $0.insert(folder) }
        #expect(throws: PersonalStateError.self) { try second.editFavorites { try $0.insert(.init(title: "Other", kind: .folder)) } }
        #expect(second.favorites.items.isEmpty)
        #expect(WorkspacePersonalState(url: url).favorites.items == [folder])
    }

    @Test func concurrentBookmarkWritersDoNotOverwriteNewerPositions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json")
        let first = WorkspacePersonalState(url: url)
        let location = ReaderLocation(resourceID: "owned", format: .legacyLSF, sectionOrdinal: 1)
        try first.setBookmark(1, location: location)
        let second = WorkspacePersonalState(url: url)
        try first.setBookmark(2, location: location)
        #expect(throws: PersonalStateError.self) { try second.setBookmark(3, location: location) }
        let reopened = WorkspacePersonalState(url: url)
        #expect(reopened.bookmarks.slots[1] == location && reopened.bookmarks.slots[2] == location)
        #expect(reopened.bookmarks.slots[3] == nil && second.bookmarks.slots[3] == nil)
    }

    @Test func incompatibleBookmarkFilesAreNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = root.appendingPathComponent("numbered-bookmarks.json")
        let bytes = Data(#"{"schemaVersion":99,"slots":{}}"#.utf8); try bytes.write(to: bookmark)
        let state = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        #expect(state.bookmarkLoadError != nil)
        #expect(throws: PersonalStateError.self) { try state.setBookmark(1, location: nil) }
        #expect(try Data(contentsOf: bookmark) == bytes)
        try state.save()
    }
}
