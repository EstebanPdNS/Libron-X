import AppKit
import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@Suite(.serialized) @MainActor struct ReaderLocationLinkWorkflowTests {
    private func settle(_ reader: ReaderSession) async throws {
        for _ in 0..<2000 { if !reader.isLoading { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Location link did not settle")
    }
    @Test func opensOnlyTheCheckedResourceAndPosition() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [["An authored reader passage"]]); defer { fixture.remove() }
        let personal = WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: personal); workspace.resources = fixture.resources
        let source = workspace.open(fixture.resources[0]); try await settle(source)
        let page = try #require(source.page)
        let location = ReaderLocation(resourceID: source.resource.id, legacyIdentifier: source.resource.legacyIdentifier,
            format: source.resource.format, sectionOrdinal: page.destination.ordinal, textFingerprint: LibrarySearchService.textFingerprint(page.text), characterOffset: 4)
        workspace.openReaderLocationLink(try ReaderLocationLink.make(location))
        let reader = try #require(workspace.activeReader); try await settle(reader)
        #expect(reader.error == nil && reader.selectedRange == NSRange(location: 4, length: 0))
        var changed = location; changed.textFingerprint = LibrarySearchService.textFingerprint("different")
        workspace.openReaderLocationLink(try ReaderLocationLink.make(changed))
        let refused = try #require(workspace.activeReader); try await settle(refused)
        #expect(refused.error != nil)
        workspace.resources = []
        workspace.openReaderLocationLink(try ReaderLocationLink.make(location))
        #expect(workspace.error != nil)
        workspace.shutdown()
    }
}
