import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct WorkspaceStartupTests {
    // Fixture snapshots must not be replaced by the developer’s managed library.
    // Tests that exercise catalog loading inject their own loader below.
    private func preferences(_ defaults: UserDefaults, mode: AppStartup) -> AppPreferences {
        let value = AppPreferences(defaults: defaults, applyAppearance: { _ in }); value.startup = mode; return value
    }
    private func wait(_ workspace: StudyWorkspace) async throws {
        for _ in 0..<200 where workspace.readers.contains(where: \.isLoading) { try await Task.sleep(for: .milliseconds(5)) }
    }
    private func archive(_ fixture: AuthoredReaderFixture) async throws -> WorkspaceArchive {
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal-authored.json")))
        workspace.resources = fixture.resources; workspace.libraryRoot = fixture.root
        let reader = workspace.open(fixture.resources[0], destination: .init(ordinal: 0))
        try await wait(workspace)
        reader.textScale = 1.25; reader.linkGroup = .b; reader.selectedRange = .init(location: 1, length: 3)
        workspace.referenceTargetID = reader.id
        let archive = workspace.archive(); try archive.validate(); return archive
    }
    @Test func normalExitSnapshotRestoresReadingSelectionLinksScaleAndCatalogInANewCoordinator() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Saved reading"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("last-workspace.json"), snapshot = try await archive(fixture)
        let store = WorkspaceStartupStore(url: url)
        #expect(try store.load() == nil); try store.save(snapshot)
        let name = "org.libronx.startup-tests." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let workspace = StudyWorkspace(), coordinator = WorkspaceStartupCoordinator(store: WorkspaceStartupStore(url: url), managedCatalog: { _ in nil })
        #expect(!(await coordinator.launch(workspace, preferences: preferences(defaults, mode: .restorePrevious), arguments: [])))
        try await wait(workspace)
        let restored = try #require(workspace.readers.first)
        #expect(restored.page?.text.contains("Saved reading") == true && restored.error == nil)
        #expect(restored.selectedRange == snapshot.panes[0].selection && restored.linkGroup == .b && restored.textScale == 1.25)
        #expect(workspace.referenceTargetID == restored.id && workspace.resources == snapshot.resources && workspace.libraryRoot == fixture.root)
        #expect(!(await coordinator.launch(workspace, preferences: preferences(defaults, mode: .library), arguments: [])))
        #expect(workspace.readers.count == 1)
        try coordinator.save(workspace)
    }
    @Test func blankHomeAndLibraryModesKeepTheCatalogWithoutRestoringReaders() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Saved reading"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("last-workspace.json"), snapshot = try await archive(fixture)
        let store = WorkspaceStartupStore(url: url); _ = try store.load(); try store.save(snapshot)
        let name = "org.libronx.startup-tests." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for mode in [AppStartup.blank, .home, .library] {
            let workspace = StudyWorkspace(), coordinator = WorkspaceStartupCoordinator(store: WorkspaceStartupStore(url: url), managedCatalog: { _ in nil })
            let openLibrary = await coordinator.launch(workspace, preferences: preferences(defaults, mode: mode), arguments: [])
            #expect(openLibrary == (mode == .library) && workspace.readers.isEmpty && workspace.resources == snapshot.resources)
            #expect(workspace.showsHome == (mode == .home) && workspace.error == nil)
        }
    }
    @Test func selectedWorkspaceReplacesTheCachedLayoutAndMissingSelectionRemainsRecoverable() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Saved reading"], ["Chosen reading"]]); defer { fixture.remove() }
        let snapshot = try await archive(fixture), chosenURL = fixture.root.appendingPathComponent("chosen.json")
        var chosen = snapshot; chosen.panes[0].resource = fixture.resources[1]; chosen.panes[0].fingerprint = nil
        let selectedFile = PersonalStateFile<WorkspaceArchive>(url: chosenURL)
        _ = try selectedFile.load(); try selectedFile.save(chosen)
        let name = "org.libronx.startup-tests." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preference = preferences(defaults, mode: .workspace); preference.startupWorkspaceURL = chosenURL
        let workspace = StudyWorkspace(recentWorkspaces: RecentWorkspaces(url: fixture.root.appendingPathComponent("recents.json")))
        await WorkspaceStartupCoordinator(store: .init(url: fixture.root.appendingPathComponent("last.json")), managedCatalog: { _ in nil }).launch(workspace, preferences: preference, arguments: [])
        try await wait(workspace)
        #expect(workspace.readers.first?.resource == fixture.resources[1] && workspace.readers.first?.page?.text.contains("Chosen reading") == true)
        #expect(workspace.recentWorkspaces.urls == [chosenURL])
        preference.startupWorkspaceURL = nil
        let missing = StudyWorkspace()
        await WorkspaceStartupCoordinator(store: .init(url: fixture.root.appendingPathComponent("last2.json")), managedCatalog: { _ in nil }).launch(missing, preferences: preference, arguments: [])
        #expect(missing.error != nil && missing.readers.isEmpty)
    }
    @Test func pendingCatalogKeepsMainActorAvailableAndProtectsSavedSession() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Saved reading"], ["New reading"]]); defer { fixture.remove() }
        let snapshot = try await archive(fixture)
        let name = "org.libronx.startup-tests." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for opensReader in [false, true] {
            let url = fixture.root.appendingPathComponent("pending-\(opensReader).json")
            let store = WorkspaceStartupStore(url: url); _ = try store.load(); try store.save(snapshot)
            let original = try Data(contentsOf: url), gate = StartupCatalogGate()
            let coordinator = WorkspaceStartupCoordinator(store: .init(url: url), managedCatalog: { _ in
                await gate.suspend(); return nil
            })
            let workspace = StudyWorkspace()
            let preference = preferences(defaults, mode: .restorePrevious)
            let launch = Task { await coordinator.launch(workspace, preferences: preference, arguments: []) }
            while !(await gate.waiting) { await Task.yield() }
            // This runs on the main actor while the directory read is suspended.
            #expect(workspace.readers.isEmpty)
            try coordinator.save(workspace)
            #expect(try Data(contentsOf: url) == original)
            if opensReader { workspace.resources = fixture.resources; _ = workspace.open(fixture.resources[1]) }
            await gate.resume(); _ = await launch.value
            try await wait(workspace)
            #expect(workspace.readers.count == 1)
            #expect(workspace.readers[0].resource == fixture.resources[opensReader ? 1 : 0])
            if opensReader { #expect(!workspace.showsHome) }
            try coordinator.save(workspace)
            #expect(try PersonalStateFile<WorkspaceArchive>(url: url).load()?.panes.count == 1)
        }
    }
    @Test func invalidAndConcurrentRecoveryCopiesCannotBeSilentlyOverwritten() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Saved reading"]]); defer { fixture.remove() }
        let snapshot = try await archive(fixture), url = fixture.root.appendingPathComponent("recovery.json")
        let original = Data("invalid previous data".utf8); try original.write(to: url)
        let store = WorkspaceStartupStore(url: url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(snapshot) }
        #expect(try Data(contentsOf: url) == original)
        try FileManager.default.removeItem(at: url)
        let valid = WorkspaceStartupStore(url: url); _ = try valid.load(); try valid.save(snapshot)
        var changed = snapshot; changed.panes[0].scale = 2
        let other = PersonalStateFile<WorkspaceArchive>(url: url); _ = try other.load(); try other.save(changed)
        #expect(throws: PersonalStateError.self) { try valid.save(snapshot) }
        #expect(try PersonalStateFile<WorkspaceArchive>(url: url).load()?.panes[0].scale == 2)
    }
}

private actor StartupCatalogGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func suspend() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}
