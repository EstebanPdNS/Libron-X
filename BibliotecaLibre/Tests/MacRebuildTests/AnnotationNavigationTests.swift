import AppKit
import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@Suite(.serialized) @MainActor struct AnnotationNavigationTests {
    private func settle(_ reader: ReaderSession) async throws {
        for _ in 0..<2000 { if !reader.isLoading { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Annotation navigation did not settle")
    }
    @Test func traversesNotesAndHighlightsAcrossArticlesAndChecksFingerprints() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [["first mark and note", "second mark"]]); defer { fixture.remove() }
        let resource = fixture.resources[0], state = WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: state); workspace.resources = [resource]
        let reader = workspace.open(resource); try await settle(reader)
        let page = try #require(reader.page), first = (page.text as NSString).range(of: "first"), noteRange = (page.text as NSString).range(of: "note")
        state.highlights = [.init(resourceID: resource.id, ordinal: 0, fingerprint: LibrarySearchService.textFingerprint(page.text), range: first, color: "yellow")]
        let loc = ReaderLocation(resourceID: resource.id, legacyIdentifier: resource.legacyIdentifier, format: resource.format, sectionOrdinal: 0,
            textFingerprint: LibrarySearchService.textFingerprint(page.text))
        var document = StudyDocument(title: "Notes", kind: .notebook)
        document.notes = [StudyNote(title: "Note", anchor: .init(kind: .nativeSelection, location: loc, selection: .init(location: noteRange.location, length: noteRange.length)))]
        state.documents = [document]
        reader.selectedRange = NSRange(location: 0, length: 0)
        workspace.navigateAnnotation(backwards: false); try await settle(reader)
        #expect(reader.selectedRange == first)
        #expect(workspace.adjacentAnnotation(for: reader, backwards: true) == nil)
        workspace.navigateAnnotation(backwards: false); try await settle(reader)
        #expect(reader.selectedRange == noteRange)
        workspace.navigateAnnotation(backwards: true); try await settle(reader)
        #expect(reader.selectedRange == first)
        state.highlights.append(.init(resourceID: resource.id, ordinal: 1, fingerprint: LibrarySearchService.textFingerprint("second mark"), range: NSRange(location: 0, length: 6), color: "blue"))
        reader.selectedRange = noteRange
        workspace.navigateAnnotation(backwards: false); try await settle(reader)
        #expect(reader.error == nil && reader.page?.destination.ordinal == 1 && reader.selectedText == "second")
        workspace.navigateAnnotation(backwards: true); try await settle(reader)
        #expect(reader.page?.destination.ordinal == 0 && reader.selectedRange == noteRange)
        state.highlights[1].fingerprint = LibrarySearchService.textFingerprint("wrong")
        workspace.navigateAnnotation(backwards: false); try await settle(reader)
        #expect(reader.error != nil && reader.page?.destination.ordinal == 0)
        workspace.shutdown()
    }
}
