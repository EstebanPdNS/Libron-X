import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct ReaderLinkPreviewTests {
    @Test func supersededPreviewAndDismissedPreviewCannotCommitEvenWhenLoaderIgnoresCancellation() async throws {
        let resource = LibraryResource(location: URL(fileURLWithPath: "/authored/book.LSF"), title: "Authored", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        let preview = ReaderLinkPreviewState(loader: { _, destination in
            try? await Task.sleep(for: .milliseconds(destination.ordinal == 1 ? 90 : 5))
            return .init(destination: destination, text: "Authored note \(destination.ordinal)", sectionCount: 10)
        })
        let first = LegacyInlineLink(range: .init(location: 1, length: 1), label: "a", sourceName: "note.a", sectionOrdinal: 1)
        let second = LegacyInlineLink(range: .init(location: 2, length: 1), label: "b", sourceName: "note.b", sectionOrdinal: 2)
        preview.load(first, resource: resource); preview.load(second, resource: resource)
        for _ in 0..<1000 where preview.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(preview.page?.text == "Authored note 2" && preview.link == second && !preview.isLoading)
        preview.load(first, resource: resource); preview.cancel()
        try await Task.sleep(for: .milliseconds(130))
        #expect(preview.page == nil && !preview.isLoading)
    }
    @Test func failedPreviewReportsItsErrorWithoutChangingSourceReaderOrHistory() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Source text"]]); defer { fixture.remove() }
        let reader = ReaderSession(resource: fixture.resources[0])
        reader.page = .init(destination: .init(ordinal: 3), text: "Retained text", sectionCount: 10)
        reader.history = [.init(ordinal: 3)]; reader.historyIndex = 0
        reader.selectedRange = .init(location: 2, length: 3)
        let preview = ReaderLinkPreviewState(loader: { _, _ in throw RebuildError.referenceNotFound })
        preview.load(.init(range: .init(location: 2, length: 1), label: "a", sourceName: "note", sectionOrdinal: 7), resource: reader.resource)
        for _ in 0..<100 where preview.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(preview.error != nil && preview.page == nil)
        #expect(reader.page?.text == "Retained text" && reader.history.count == 1 && reader.historyIndex == 0)
        #expect(reader.selectedRange == NSRange(location: 2, length: 3))
    }
}
