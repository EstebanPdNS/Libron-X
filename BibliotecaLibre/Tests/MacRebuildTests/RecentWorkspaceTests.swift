import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct RecentWorkspaceTests {
    private func store(_ fixture: AuthoredReaderFixture) -> RecentWorkspaces {
        RecentWorkspaces(url: fixture.root.appendingPathComponent("recents.json"))
    }
    private func workspace(_ fixture: AuthoredReaderFixture, recents: RecentWorkspaces) -> StudyWorkspace {
        StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")),
            resourceVisibility: LibraryResourceVisibility(url: fixture.root.appendingPathComponent("hidden.json")), recentWorkspaces: recents)
    }
    @Test func mruPersistsTenEntriesDeduplicatesNormalizedPathsAndPromotesReopenedFiles() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored"]]); defer { fixture.remove() }
        let recents = store(fixture), files = (0..<12).map { fixture.root.appendingPathComponent("Workspace \($0).libronx.json") }
        for file in files { try Data("owned fixture".utf8).write(to: file); try recents.record(file) }
        #expect(recents.urls == Array(files.suffix(10).reversed()))
        let alias = fixture.root.appendingPathComponent("unused/../Workspace 4.libronx.json")
        try recents.record(alias)
        #expect(recents.urls.first == files[4] && recents.urls.count == 10 && recents.urls.filter { $0 == files[4] }.count == 1)
        #expect(store(fixture).urls == recents.urls)
    }
    @Test func equalUnicodeNamesRemainDistinctAndClearOnlyRemovesMetadata() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored"]]); defer { fixture.remove() }
        let recents = store(fixture)
        let files = ["A", "B"].map { fixture.root.appendingPathComponent($0).appendingPathComponent("Estudio & oración 😀.libronx.json") }
        let bytes = Data("Owned workspace sentinel".utf8)
        for file in files {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file); try recents.record(file)
        }
        #expect(RecentWorkspaces.title(for: files[0]) == "Estudio & oración 😀")
        #expect(recents.menuTitle(for: files[0]) != recents.menuTitle(for: files[1]))
        #expect(recents.menuTitle(for: files[0]).contains(files[0].deletingLastPathComponent().path))
        try recents.clear(); #expect(recents.urls.isEmpty && store(fixture).urls.isEmpty)
        for file in files { #expect(try Data(contentsOf: file) == bytes) }
    }
    @Test func menuRefreshPrunesMissingFilesAndReplacedDirectoriesWithoutRemovingValidFiles() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored"]]); defer { fixture.remove() }
        let recents = store(fixture), valid = fixture.root.appendingPathComponent("valid.json")
        let missing = fixture.root.appendingPathComponent("missing.json"), directory = fixture.root.appendingPathComponent("directory.json")
        try Data("retained".utf8).write(to: valid)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in [valid, missing, directory] { try recents.record(file) }
        try recents.refreshPruningMissingFiles()
        #expect(recents.urls == [valid] && store(fixture).urls == [valid])
        #expect(try Data(contentsOf: valid) == Data("retained".utf8))
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }
    @Test func malformedFutureAndRemoteHistoryFilesCannotBeReplaced() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored"]]); defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("recents.json")
        for bytes in [Data("invalid".utf8), Data("{\"schemaVersion\":99,\"urls\":[]}".utf8),
                      try JSONEncoder().encode(RecentWorkspaceSnapshot(urls: [URL(string: "https://example.invalid/workspace.json")!]))] {
            try bytes.write(to: file)
            let recents = store(fixture)
            #expect(recents.loadError != nil && recents.urls.isEmpty)
            #expect(throws: (any Error).self) { try recents.record(fixture.root.appendingPathComponent("new.json")) }
            #expect(throws: (any Error).self) { try recents.clear() }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
    @Test func concurrentHistoryWritesAreRejectedThenExplicitRefreshMergesTheCurrentList() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored"]]); defer { fixture.remove() }
        let files = ["a.json", "b.json", "c.json"].map { fixture.root.appendingPathComponent($0) }
        for file in files { try Data("fixture".utf8).write(to: file) }
        let first = store(fixture); try first.record(files[0])
        let other = store(fixture); try other.record(files[1])
        #expect(throws: PersonalStateError.self) { try first.record(files[2]) }
        #expect(store(fixture).urls == [files[1], files[0]])
        try first.refreshPruningMissingFiles(); try first.record(files[2])
        #expect(store(fixture).urls == [files[2], files[1], files[0]])
    }
    @Test func validatedSaveAndLoadRegisterHistoryButFailedFilesPreserveTheLiveWorkspace() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored"]]); defer { fixture.remove() }
        let recents = store(fixture), workspace = workspace(fixture, recents: recents)
        workspace.resources = fixture.resources; let first = workspace.open(fixture.resources[0], startReading: false)
        first.textScale = 1.5
        let a = fixture.root.appendingPathComponent("a.libronx.json"), b = fixture.root.appendingPathComponent("b.libronx.json")
        try workspace.saveWorkspace(to: a)
        first.textScale = 2; try workspace.saveWorkspace(to: b)
        #expect(recents.urls == [b, a])
        try workspace.loadWorkspace(at: a)
        #expect(workspace.activeReader?.textScale == 1.5 && recents.urls == [a, b])
        let liveID = workspace.activeID, invalid = fixture.root.appendingPathComponent("invalid.json")
        let badBytes = Data("invalid workspace".utf8); try badBytes.write(to: invalid); try recents.record(invalid)
        #expect(throws: (any Error).self) { try workspace.loadWorkspace(at: invalid) }
        #expect(workspace.activeID == liveID && workspace.readers.count == 1 && !recents.urls.contains(invalid))
        #expect(try Data(contentsOf: invalid) == badBytes)
        let missing = fixture.root.appendingPathComponent("missing.json"); try recents.record(missing)
        #expect(throws: WorkspaceFileFailure.self) { try workspace.loadWorkspace(at: missing) }
        #expect(workspace.activeID == liveID && !recents.urls.contains(missing))
        workspace.clearRecentWorkspaces(); #expect(recents.urls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }
    @Test func successfulWorkspaceSaveAndLoadAreDisclosedSeparatelyFromHistoryFailures() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored"]]); defer { fixture.remove() }
        let history = fixture.root.appendingPathComponent("recents.json"), historyBytes = Data("invalid history".utf8)
        try historyBytes.write(to: history)
        let workspace = workspace(fixture, recents: store(fixture)); workspace.open(fixture.resources[0], startReading: false)
        let file = fixture.root.appendingPathComponent("valid.libronx.json")
        try workspace.saveWorkspace(to: file)
        let savedWarning = try #require(workspace.error)
        workspace.error = nil; try workspace.loadWorkspace(at: file)
        let loadedWarning = try #require(workspace.error)
        #expect(workspace.readers.count == 1 && savedWarning != loadedWarning)
        #expect(try Data(contentsOf: history) == historyBytes)
    }
}
