import AppKit
import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@Suite(.serialized) @MainActor struct ResearchInboxTests {
    private func settle(_ reader: ReaderSession) async throws {
        for _ in 0..<2000 { if !reader.isLoading { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Reader did not settle")
    }
    @Test func capturePersistsAndReopensTheExactSelection() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [["Before 😀 selected text after"]]); defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent("personal.json")
        let personal = WorkspacePersonalState(url: path)
        let workspace = StudyWorkspace(personal: personal, resourceVisibility: .init(url: fixture.root.appendingPathComponent("hidden.json")))
        workspace.resources = fixture.resources
        let reader = workspace.open(fixture.resources[0]); try await settle(reader)
        let page = try #require(reader.page)
        let selected = (page.text as NSString).range(of: "selected text")
        reader.selectedRange = selected
        #expect(workspace.canCaptureResearchExcerpt)
        workspace.captureResearchExcerpt()
        let excerpt = try #require(personal.researchInbox.excerpts.first)
        #expect(excerpt.text == "selected text" && excerpt.selectionLength == selected.length)
        #expect(WorkspacePersonalState(url: path).researchInbox.excerpts == [excerpt])
        workspace.openResearchExcerpt(excerpt)
        let reopened = try #require(workspace.activeReader); try await settle(reopened)
        #expect(reopened.error == nil && reopened.selectedText == "selected text" && reopened.selectedRange == selected)
        var stale = excerpt; stale.location.textFingerprint = LibrarySearchService.textFingerprint("Changed source")
        workspace.openResearchExcerpt(stale)
        let refused = try #require(workspace.activeReader); try await settle(refused)
        #expect(refused.error != nil)
        workspace.resources = []
        workspace.openResearchExcerpt(excerpt)
        #expect(workspace.error != nil)
        workspace.shutdown()
    }
    @Test func rejectsInvalidOffsetsAndProtectsConcurrentChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("personal.json")
        let first = WorkspacePersonalState(url: path), stale = WorkspacePersonalState(url: path)
        let location = ReaderLocation(resourceID: "resource", format: .legacyLSF, sectionOrdinal: 0, textFingerprint: String(repeating: "a", count: 64), characterOffset: 0)
        let excerpt = ResearchExcerpt(sourceTitle: "Source", text: "abc", location: location, selectionLength: 3)
        try first.editResearchInbox { $0.excerpts.append(excerpt) }
        #expect(throws: (any Error).self) { try stale.editResearchInbox { $0.excerpts.append(excerpt) } }
        var invalid = excerpt; invalid.selectionLength = 4
        #expect(throws: (any Error).self) { try first.editResearchInbox { $0.excerpts = [invalid] } }
        #expect(first.researchInbox.excerpts == [excerpt])
    }
    @Test func closeKeepsInboxOpenWhenDraftCannotBeSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: personal, resourceVisibility: .init(url: root.appendingPathComponent("hidden.json")))
        workspace.activeTool = .researchInbox; workspace.researchDraftSaver = { false }
        workspace.closeActiveTool(); #expect(workspace.activeTool == .researchInbox)
        workspace.researchDraftSaver = { true }
        workspace.closeActiveTool(); #expect(workspace.activeTool == nil)
        workspace.shutdown()
    }
}
