import Foundation
import LibronixCore

/// Results keep their source field and UTF-16 range so a document edit can be
/// detected before the user copies or imports an extracted reference.
struct ExtractedStudyReference: Identifiable, Sendable {
    let id = UUID()
    let mention: BibleReferenceMention
    let reference: String
    let sourceTitle: String
    let documentDestination: BibleReferencePersonalDestination?
}
struct StudyReferenceExtraction: Sendable {
    let items: [ExtractedStudyReference]
    let warnings: [String]
    let complete: Bool

    static func text(_ text: String, links: [BibleReferenceSourceLink] = [], title: String) throws -> Self {
        let field = BibleReferencePersonalField(kind: .noteBody, text: text, links: links)
        return try project([field], title: title, documentID: nil, warnings: [], complete: true)
    }
    static func document(_ document: StudyDocument) throws -> Self {
        let source = try PersonalReferenceProjection.source(document)
        return try project(source.fields, title: source.title, documentID: source.documentID,
                           warnings: source.warnings, complete: source.projectionComplete)
    }
    func validate(against documents: [StudyDocument]) throws {
        for item in items {
            if let destination = item.documentDestination {
                _ = try PersonalReferenceProjection.validate(destination, documents: documents)
            }
        }
    }
    private static func project(_ fields: [BibleReferencePersonalField], title: String, documentID: UUID?,
                                warnings: [String], complete: Bool) throws -> Self {
        var items: [ExtractedStudyReference] = [], units = 0
        for field in fields {
            try Task.checkCancellation()
            let count = field.text.utf16.count
            guard count <= 2_000_000 - units else { throw BibleReferenceSearchError.sourceLimit }
            units += count
            let fieldFingerprint = try field.projectionFingerprint()
            for mention in try BibleReferenceMentions.extract(field.text, links: field.links) {
                guard items.count < 10_000 else { throw BibleReferenceSearchError.mentionLimit }
                let reference: String
                if mention.origin == .explicitLink {
                    guard let link = field.links.first(where: { $0.range == mention.range }) else {
                        throw BibleReferenceSearchError.invalidRange
                    }
                    if link.target.hasPrefix("=r"), let legacy = LegacyBibleLinkReference.parse(link.target) {
                        let a = legacy.passage.start, b = legacy.passage.end
                        reference = "\(a.bookKey) \(a.chapter):\(a.verse)" +
                            (a == b ? "" : "-\(b.bookKey) \(b.chapter):\(b.verse)") +
                            (legacy.edition.map { "(" + $0 + ")" } ?? "")
                    } else { reference = link.target }
                } else { reference = mention.label }
                guard let parsed = try? BibleReferenceQuery.parse(reference),
                      parsed.citations == [mention.citation] else { throw BibleReferenceSearchError.invalidQuery }
                let destination = documentID.map {
                    BibleReferencePersonalDestination(documentID: $0, entryID: field.entryID, field: field.kind,
                        textSHA256: LibrarySearchService.textFingerprint(field.text), projectionSHA256: fieldFingerprint,
                        range: mention.range)
                }
                items.append(.init(mention: mention, reference: reference, sourceTitle: title, documentDestination: destination))
            }
        }
        return .init(items: items, warnings: warnings, complete: complete)
    }
}
