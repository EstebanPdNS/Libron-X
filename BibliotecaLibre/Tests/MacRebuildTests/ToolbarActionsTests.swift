import AppKit
import PDFKit
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct ToolbarActionsTests {
    private func workspace(_ root: URL) -> StudyWorkspace {
        StudyWorkspace(personal: WorkspacePersonalState(url: root.appendingPathComponent("personal.json")))
    }
    private func settle(_ reader: ReaderSession) async throws {
        for _ in 0..<1000 { if !reader.isLoading { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Reader did not settle")
    }
    @Test func duplicateRetainsLocationAndSelectionButNavigationRemainsIndependent() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["First α 😀", "Second"]]); defer { fixture.remove() }
        let workspace = workspace(fixture.root)
        let reader = workspace.open(fixture.resources[0]); try await settle(reader)
        reader.selectedRange = NSRange(location: 6, length: 4); reader.textScale = 1.5; reader.showsContents = true
        let copy = workspace.duplicate(reader)
        #expect(copy.id != reader.id && copy.page?.text == reader.page?.text)
        #expect(copy.selectedRange == reader.selectedRange && copy.textScale == 1.5 && copy.showsContents)
        copy.nextArticle(); try await settle(copy)
        #expect(copy.page?.text == "Second" && reader.page?.text == "First α 😀")
        workspace.cycleReader(); #expect(workspace.activeReader === reader)
        workspace.minimize(copy); workspace.cycleReader()
        #expect(workspace.activeReader === copy && !copy.isMinimized)
    }
    @Test func workspaceArchiveRoundTripRestoresPanesLinksTargetAndCommittedSelection() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["One", "Second 😀"]]); defer { fixture.remove() }
        let source = workspace(fixture.root); source.resources = fixture.resources
        let first = source.open(fixture.resources[0]); try await settle(first)
        first.nextArticle(); try await settle(first)
        first.selectedRange = NSRange(location: 7, length: 2); first.linkGroup = .b; first.textScale = 1.25
        first.showsLocator = true; first.changeLocatorMode(true)
        let second = source.duplicate(first); source.minimize(second)
        source.referenceTargetID = first.id; source.arrange(.horizontal)
        let encoded = try JSONEncoder().encode(source.archive())
        let decoded = try JSONDecoder().decode(WorkspaceArchive.self, from: encoded)
        let restored = workspace(fixture.root); try restored.restore(decoded)
        for reader in restored.readers { try await settle(reader) }
        #expect(restored.readers.count == 2 && restored.readers[1].isMinimized)
        let reader = try #require(restored.activeReader)
        #expect(reader.page?.text == "Second 😀" && reader.selectedText == "😀")
        #expect(reader.showsLocator && reader.locatorIsArticle && reader.locator == "2")
        #expect(reader.linkGroup == .b && restored.referenceTargetID == reader.id)
        #expect(reader.history.map(\.ordinal) == [0,1] && reader.canGoBack)
    }
    @Test func invalidAndFutureArchivesCannotReplaceTheCurrentWorkspace() throws {
        let fixture = try AuthoredReaderFixture(documents: [["One"]]); defer { fixture.remove() }
        let workspace = workspace(fixture.root)
        let retained = workspace.open(fixture.resources[0], startReading: false)
        var archive = workspace.archive(); archive.schemaVersion = 99
        #expect(throws: PersonalStateError.self) { try workspace.restore(archive) }
        #expect(workspace.activeReader === retained)
        archive.schemaVersion = 1; archive.panes[0].frame.x = .infinity
        #expect(throws: PersonalStateError.self) { try workspace.restore(archive) }
        #expect(workspace.readers.count == 1)
    }
    @Test func highlightsFavoritesAndAnchoredNotesSurviveNewAppPersonalStorage() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["First 😀 text"]]); defer { fixture.remove() }
        let workspace = workspace(fixture.root); workspace.resources = fixture.resources
        let reader = workspace.open(fixture.resources[0]); try await settle(reader)
        reader.selectedRange = NSRange(location: 6, length: 2)
        workspace.addHighlight("yellow"); workspace.addFavorite(); workspace.addNoteForSelection(reader)
        let reloaded = WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json"))
        #expect(reloaded.loadError == nil && reloaded.highlights.count == 1 && reloaded.favorites.items.count == 1)
        let note = try #require(reloaded.documents.first?.notes.first)
        #expect(note.sourceBody == "😀" && note.anchor.kind == .nativeSelection && note.anchor.selection?.length == 2)
        let bytes = try Data(contentsOf: fixture.resources[0].location)
        workspace.eraseHighlight(); #expect(reader.highlights.isEmpty)
        #expect(try Data(contentsOf: fixture.resources[0].location) == bytes)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("personal.json.previous").path))
    }
    @Test func futurePersonalFilesAndConcurrentChangesArePreserved() throws {
        let fixture = try AuthoredReaderFixture(documents: [["One"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("personal.json")
        let future = Data("{\"schemaVersion\":99,\"favorites\":{\"schemaVersion\":1,\"items\":[]},\"highlights\":[],\"documents\":[]}".utf8)
        try future.write(to: url)
        let refused = WorkspacePersonalState(url: url)
        #expect(refused.loadError != nil)
        #expect(throws: PersonalStateError.self) { try refused.save() }
        #expect(try Data(contentsOf: url) == future)
        try FileManager.default.removeItem(at: url)
        let first = WorkspacePersonalState(url: url), second = WorkspacePersonalState(url: url)
        first.create(.notebook); try first.save()
        #expect(throws: PersonalStateError.self) { try second.save() }
    }
    @Test func committedOutputPreservesUnicodeAndProducesReadableTextRTFDAndPDF() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored output α 😀"]]); defer { fixture.remove() }
        let reader = ReaderSession(resource: fixture.resources[0]); reader.load(.init(ordinal: 0)); try await settle(reader)
        let whole = try ReaderOutputActions.document(reader)
        #expect(whole.string == "Authored output α 😀")
        reader.selectedRange = NSRange(location: 18, length: 2)
        #expect(try ReaderOutputActions.document(reader, selectionOnly: true).string == "😀")
        let txt = fixture.root.appendingPathComponent("output.txt")
        try ReaderOutputActions.write(whole, to: txt, type: "txt")
        #expect(try String(contentsOf: txt, encoding: .utf8) == whole.string)
        let rtfd = fixture.root.appendingPathComponent("output.rtfd")
        try ReaderOutputActions.write(whole, to: rtfd, type: "rtfd")
        let decoded = try NSAttributedString(url: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        #expect(decoded.string == whole.string)
        let pdf = fixture.root.appendingPathComponent("output.pdf")
        try ReaderOutputActions.write(whole, to: pdf, type: "pdf")
        #expect(PDFDocument(url: pdf)?.string?.contains("Authored output") == true)
    }
    @Test func searchToolbarReturnsResultsAndOpensOnlySourceVerifiedSelections() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Cover", "Gamma then gamma"]]); defer { fixture.remove() }
        let workspace = workspace(fixture.root); workspace.resources = fixture.resources
        workspace.search.resourceID = fixture.resources[0].id; workspace.search.query = "Gamma"
        workspace.search.run(workspace.resources)
        for _ in 0..<1000 { if !workspace.search.isSearching { break }; try await Task.sleep(for: .milliseconds(5)) }
        let result = try #require(workspace.search.report?.results.first)
        workspace.openSearchResult(result)
        let reader = try #require(workspace.activeReader); try await settle(reader)
        #expect(reader.selectedText == "Gamma" && reader.page?.destination.ordinal == 1)
        #expect(workspace.search.report?.coverageComplete == true)
    }
    @Test func changedSearchTextCannotApplyStaleSelectionOrReplaceCommittedPage() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Keep", "Actual"]]); defer { fixture.remove() }
        let reader = ReaderSession(resource: fixture.resources[0]); reader.load(.init(ordinal: 0)); try await settle(reader)
        reader.load(.init(ordinal: 1), selection: NSRange(location: 0, length: 5), expectedFingerprint: LibrarySearchService.textFingerprint("Wrong"))
        try await settle(reader)
        #expect(reader.page?.text == "Keep" && reader.error != nil && reader.history.count == 1)
    }
}

@MainActor struct LocalToolbarCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_TOOLBAR_CORPUS"] != nil))
    func linkedBibleReadersResolveEachEditionWithoutCrossCopyingOrdinals() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_TOOLBAR_CORPUS"]))
        let personal = WorkspacePersonalState(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/personal.json"))
        let workspace = StudyWorkspace(personal: personal)
        func resource(_ file: String) throws -> LibraryResource {
            let url = directory.appendingPathComponent(file), metadata = try LegacyResourceReader.inspect(lsfURL: url).lsf
            return .init(location: url, title: metadata.title ?? file, byteCount: Int64(try LegacyGraphicsService.fileStamp(url).size),
                         format: .legacyLSF, support: .metadataOnly, provenance: .legacyPublicMetadata, legacyIdentifier: metadata.bkidHex)
        }
        let first = workspace.open(try resource("RVR60.LSF"), startReading: false), second = workspace.open(try resource("RVR95.LSF"), startReading: false)
        first.linkGroup = .a; second.linkGroup = .a
        first.load(.init(ordinal: 0, reference: "Juan 1:1"))
        for _ in 0..<2000 {
            if first.page != nil && second.page != nil && !first.isLoading && !second.isLoading { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(first.page?.destination.ordinal == 6479 && second.page?.destination.ordinal == 19437)
        #expect(first.history.count == 1 && second.history.count == 1)
        let document = try await BibleCopyService().prepare(first.resource, passage: .parse("Juan 1:1-2"), abbreviation: "RVR60")
        let formatted = try BibleCopyFormatter.format(document, style: .init(name: "Toolbar control"), referenceLanguage: .spanish)
        #expect(document.verses.count == 2 && formatted.plainText.contains("En el principio era el Verbo"))
        print("Linked toolbar control: RVR60=6479, RVR95=19437, no feedback loop; Copy Bible Verses=2 verses")
    }
}
