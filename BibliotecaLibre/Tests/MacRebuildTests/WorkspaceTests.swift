import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct WorkspaceTests {
    private func resource(_ title: String = "Authored resource") -> LibraryResource {
        .init(location: URL(fileURLWithPath: "/authored/\(title).LSF"), title: title, byteCount: 0,
              format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
    }
    @Test func duplicateBooksHaveIndependentReadersAndCloseDoesNotCloseTheWorkspace() {
        let workspace = StudyWorkspace()
        let first = workspace.open(resource(), startReading: false)
        let second = workspace.open(resource(), startReading: false)
        first.locator = "John 1:1"
        #expect(first.id != second.id && second.locator.isEmpty)
        workspace.close(second)
        #expect(workspace.activeReader === first && workspace.readers.count == 1)
        workspace.close(first)
        #expect(workspace.readers.isEmpty && workspace.activeID == nil)
    }
    @Test func activationMinimizationAndRestorePreservePaneState() {
        let workspace = StudyWorkspace()
        let first = workspace.open(resource("One"), startReading: false)
        let second = workspace.open(resource("Two"), startReading: false)
        first.locator = "Saved draft"
        workspace.activate(first)
        #expect(workspace.readers.last === first)
        workspace.minimize(first)
        #expect(workspace.activeReader === second && workspace.visibleReaders.count == 1)
        workspace.activate(first)
        #expect(workspace.activeReader === first && !first.isMinimized && first.locator == "Saved draft")
    }
    @Test func focusChangesKeepPresentationSiblingsStableAndOnlyChangeTheirStackingLevels() {
        let workspace = StudyWorkspace()
        let readers = (1...4).map { workspace.open(resource("Pane \($0)"), startReading: false) }
        let ids = readers.map(\.id)
        for index in [0, 2, 1, 3, 0, 2] {
            workspace.activate(readers[index])
            #expect(workspace.presentedReaders.map(\.id) == ids)
            #expect(workspace.stackingLevel(of: readers[index]) == 3)
            #expect(workspace.readers.last === readers[index])
        }
        workspace.minimize(readers[1])
        #expect(workspace.presentedReaders.map(\.id) == [ids[0], ids[2], ids[3]])
        workspace.activate(readers[1])
        #expect(workspace.presentedReaders.map(\.id) == ids && workspace.stackingLevel(of: readers[1]) == 3)
        workspace.close(readers[0])
        #expect(workspace.presentedReaders.map(\.id) == Array(ids.dropFirst()))
        let copy = workspace.duplicate(readers[2])
        #expect(workspace.presentedReaders.map(\.id) == Array(ids.dropFirst()) + [copy.id])
    }
    @Test func tilePartitionsCanvasAndDoesNotRestoreMinimizedPanes() {
        let workspace = StudyWorkspace()
        let first = workspace.open(resource("One"), startReading: false)
        let second = workspace.open(resource("Two"), startReading: false)
        let third = workspace.open(resource("Three"), startReading: false)
        workspace.minimize(third); first.isMaximized = true
        workspace.arrange(.vertical)
        #expect(first.frame == .init(x: 0, y: 0, width: 0.5, height: 1))
        #expect(second.frame == .init(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(!first.isMaximized && third.isMinimized)
        workspace.arrange(.horizontal)
        #expect(first.frame == .init(x: 0, y: 0, width: 1, height: 0.5))
        #expect(second.frame == .init(x: 0, y: 0.5, width: 1, height: 0.5))
    }
    @Test func draggingAndResizingCannotLoseTheTitleBarOutsideCanvas() {
        let constrained = PaneFrame(x: -3, y: 9, width: 0.8, height: 0.7).constrained()
        #expect(constrained.x == 0 && abs(constrained.y - 0.3) < 0.000001)
        #expect(PaneFrame(x: 1, y: 1, width: 2, height: 3).constrained() == .init(x: 0, y: 0, width: 1, height: 1))
    }
    @Test func filteringDoesNotReplaceTheSelectedReaders() {
        let workspace = StudyWorkspace()
        workspace.resources = [resource("Alpha"), resource("Beta")]
        let reader = workspace.open(workspace.resources[0], startReading: false)
        workspace.libraryQuery = "Beta"
        #expect(workspace.filteredResources.map(\.title) == ["Beta"])
        #expect(workspace.activeReader === reader)
        workspace.libraryQuery = "Missing"
        #expect(workspace.filteredResources.isEmpty && workspace.readers.count == 1)
    }
    private var loader: ReaderSession.Loader {
        { _, destination in
            if destination.ordinal == 1 { throw RebuildError.referenceNotFound }
            return ReaderPage(destination: destination, text: "Article \(destination.ordinal)", sectionCount: 5)
        }
    }
    private func settle(_ reader: ReaderSession) async throws {
        for _ in 0..<200 {
            if !reader.isLoading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Reader did not settle")
    }
    @Test func failedNavigationRetainsCommittedContentAndHistory() async throws {
        let reader = ReaderSession(resource: resource(), loader: loader)
        reader.load(.init(ordinal: 0)); try await settle(reader)
        reader.load(.init(ordinal: 1)); try await settle(reader)
        #expect(reader.page?.text == "Article 0" && reader.error != nil)
        #expect(reader.history.map(\.ordinal) == [0] && reader.historyIndex == 0)
    }
    @Test func backForwardAndBranchingHistoryCommitOnlySuccessfulReads() async throws {
        let reader = ReaderSession(resource: resource(), loader: loader)
        reader.load(.init(ordinal: 0)); try await settle(reader)
        reader.load(.init(ordinal: 2)); try await settle(reader)
        reader.goBack(); try await settle(reader)
        #expect(reader.page?.destination.ordinal == 0 && reader.canGoForward)
        reader.goForward(); try await settle(reader)
        #expect(reader.page?.destination.ordinal == 2 && reader.history.count == 2)
        reader.goBack(); try await settle(reader)
        reader.load(.init(ordinal: 3)); try await settle(reader)
        #expect(reader.history.map(\.ordinal) == [0, 3] && !reader.canGoForward)
    }
    @Test func supersededRequestsCannotCommitToReaderHistory() async throws {
        let reader = ReaderSession(resource: resource(), loader: loader)
        reader.load(.init(ordinal: 0)); reader.load(.init(ordinal: 2))
        try await settle(reader)
        #expect(reader.history.map(\.ordinal) == [2] && reader.page?.text == "Article 2")
    }
    @Test func explicitCancellationDoesNotCreateAnArticleOrHistoryEntry() async throws {
        let reader = ReaderSession(resource: resource(), loader: loader)
        reader.load(.init(ordinal: 0)); reader.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(reader.page == nil && reader.history.isEmpty && !reader.isLoading)
    }
    @Test func actualAdapterReadsUnicodeAndSurvivesMissingIndexAndCorruptArticle() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored α 😀 first", nil, "Authored last"]])
        defer { fixture.remove() }
        let sourceBefore = try Data(contentsOf: fixture.resources[0].location)
        let reader = ReaderSession(resource: fixture.resources[0])
        reader.load(.init(ordinal: 0)); try await settle(reader)
        #expect(reader.page?.text == "Authored α 😀 first" && reader.page?.sectionCount == 3)
        #expect(reader.page?.warning != nil && reader.error == nil)
        reader.load(.init(ordinal: 1)); try await settle(reader)
        #expect(reader.page?.text == "Authored α 😀 first" && reader.error != nil)
        reader.load(.init(ordinal: 2)); try await settle(reader)
        #expect(reader.page?.text == "Authored last" && reader.history.map(\.ordinal) == [0, 2])
        #expect(try Data(contentsOf: fixture.resources[0].location) == sourceBefore)
    }
    @Test func actualOEBAdapterReportsMissingFilesWithoutInventingContent() async {
        let opaque = LibraryResource(location: URL(fileURLWithPath: "/missing.lbxoeb"), title: "Opaque", byteCount: 0,
            format: .libronixOEB, support: .opaqueContainer, provenance: .fileName)
        do { _ = try await ReaderSession.read(opaque, .init(ordinal: 0)); Issue.record("Unexpected format acceptance") }
        catch { #expect((error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileReadNoSuchFileError) }
    }
}
