import Foundation
import LibronixCore

struct ReadingPlanTarget: Sendable {
    let resource: LibraryResource
    let verse: BiblePassageVerse
    let sourceStamps: [LibrarySearchFileStamp]
}

/// Resolve the first requested address against source text, including its
/// explicit edition qualifier. A reader title is not evidence of an edition.
actor ReadingPlanNavigator {
    private let service: BiblePassageReportService
    init(provider: any LibrarySearchContentProvider = WorkspaceSearchReader()) {
        service = .init(provider: provider)
    }
    func target(_ reference: String, in resource: LibraryResource) async throws -> ReadingPlanTarget {
        try Task.checkCancellation()
        let query = try BibleReferenceQuery.parse(reference)
        guard let citation = query.citations.first, let address = citation.spans.first?.lower else {
            throw BibleReferenceSearchError.invalidQuery
        }
        let key = "\(address.book) \(max(1, address.chapter)):\(max(1, address.verse))"
        let qualified = citation.edition.map { key + "(" + $0 + ")" } ?? key
        let report = try await service.read(resource, range: .parse(qualified))
        try Task.checkCancellation()
        if let failure = report.failure { throw PersonalStateError.invalid(failure) }
        guard let verse = report.verses.first(where: { $0.key == key }) else {
            throw PersonalStateError.invalid("El inicio del pasaje no está verificado en esta edición. Elige otra Biblia o revisa la referencia.")
        }
        try LibrarySearchFileStamp.verify(report.sourceStamps)
        return .init(resource: report.resource, verse: verse, sourceStamps: report.sourceStamps)
    }
}
