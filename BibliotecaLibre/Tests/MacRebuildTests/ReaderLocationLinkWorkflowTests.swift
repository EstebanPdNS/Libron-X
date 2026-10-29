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
    @Test func webLocationUsesOnlyAReadyVerifiedProjection() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(); defer { fixture.remove() }
        let personal = WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: personal); workspace.resources = [fixture.resource]
        let reader = workspace.open(fixture.resource, startReading: false)
        reader.load(.init(ordinal: 0)); try await settle(reader)
        let page = try #require(reader.page?.oeb)
        #expect(workspace.currentBookmarkLocation == nil)
        let projection = try await ReaderOEBTextSource.shared.read(book: page.book, path: "Cover.html", viewport: .init())
        try reader.acceptOEBProjection(projection.text, at: page.url)
        reader.selectedRange = NSRange(location: 2, length: 0)
        let location = try #require(workspace.currentBookmarkLocation)
        #expect(location.resourceID == fixture.resource.id && location.textFingerprint == projection.fingerprint && location.characterOffset == 2)
        workspace.addFavorite()
        let favoriteLocation = try #require(workspace.personal.favorites.items.first?.location)
        #expect(favoriteLocation.textFingerprint == projection.fingerprint && favoriteLocation.characterOffset == 2)
        workspace.openReaderLocationLink(try ReaderLocationLink.make(location))
        let target = try #require(workspace.activeReader); try await settle(target)
        let destination = try #require(target.page?.oeb)
        try target.acceptOEBProjection(projection.text, at: destination.url)
        #expect(target.selectedRange == NSRange(location: 2, length: 0))
        target.load(.init(ordinal: 0), selection: NSRange(location: 2, length: 0), expectedFingerprint: projection.fingerprint)
        try await settle(target)
        let changedPage = try #require(target.page?.oeb)
        try Data("changed".utf8).write(to: fixture.resource.location)
        #expect(throws: LibronixBookError.sourceChanged) { try target.acceptOEBProjection(projection.text, at: changedPage.url) }
        workspace.shutdown()
    }

}
