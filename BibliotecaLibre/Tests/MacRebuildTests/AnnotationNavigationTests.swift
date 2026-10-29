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
    @Test func overlappingAnnotationsRemainSeparateStops() throws {
        let fixture = try AuthoredReaderFixture(documents: [["same location"]]); defer { fixture.remove() }
        let resource = fixture.resources[0], state = WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: state); let reader = workspace.open(resource, startReading: false)
        let text = "same location", range = NSRange(location: 0, length: 4), fingerprint = LibrarySearchService.textFingerprint(text)
        reader.page = ReaderPage(destination: .init(ordinal: 0), text: text, sectionCount: 1); reader.selectedRange = range
        state.highlights = [.init(resourceID: resource.id, ordinal: 0, fingerprint: fingerprint, range: range, color: "yellow"),
                            .init(resourceID: resource.id, ordinal: 0, fingerprint: fingerprint, range: range, color: "blue")]
        let stops = workspace.annotationDestinations(for: reader); #expect(stops.count == 2)
        workspace.annotationNavigationCursor = .init(readerID: reader.id, destination: stops[0])
        #expect(workspace.adjacentAnnotation(for: reader, backwards: false) == stops[1])
        workspace.annotationNavigationCursor = .init(readerID: reader.id, destination: stops[1])
        #expect(workspace.adjacentAnnotation(for: reader, backwards: true) == stops[0])
        workspace.shutdown()
    }
    @Test func webAnnotationsVerifyTheirSourceBeforeChangingThePage() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(); defer { fixture.remove() }
        let personal = WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: personal), reader = workspace.open(fixture.resource, startReading: false)
        reader.load(.init(ordinal: 0)); try await settle(reader)
        let cover = try #require(reader.page?.oeb)
        let coverText = try await ReaderOEBTextSource.shared.read(book: cover.book, path: "Cover.html", viewport: .init()).text
        try reader.acceptOEBProjection(coverText, at: cover.url)
        let chapter = try await ReaderOEBTextSource.shared.read(book: cover.book, path: "Chapter.html", viewport: .init())
        let range = (chapter.text as NSString).range(of: "Gamma")
        workspace.personal.highlights = [.init(resourceID: fixture.resource.id, ordinal: 1, fingerprint: chapter.fingerprint, range: range, color: "yellow")]
        workspace.navigateAnnotation(backwards: false); try await settle(reader)
        let candidate = try #require(reader.page?.oeb)
        #expect(reader.committedPage?.destination.ordinal == 0)
        #expect(throws: LibronixBookError.sourceChanged) { try reader.acceptOEBProjection("changed", at: candidate.url) }
        #expect(reader.page?.destination.ordinal == 0)
        workspace.navigateAnnotation(backwards: false); try await settle(reader)
        let next = try #require(reader.page?.oeb)
        try reader.acceptOEBProjection(chapter.text, at: next.url)
        #expect(reader.page?.destination.ordinal == 1 && reader.selectedText == "Gamma")
        workspace.shutdown()
    }

}
