import Foundation
import LibronixCore

/// Cache source ownership ranges separately from rendered chapter pages.
/// Citations in the body of a note never establish commentary coverage.
actor CommentaryCoverageCatalog {
    static let shared = CommentaryCoverageCatalog()
    private struct StoredRange: Decodable { var start: String; var end: String; var ordinal: Int }
    private struct Span {
        var chapter: Int; var verse: Int; var endChapter: Int; var endVerse: Int
    }
    private var coverage: [URL: [String: [Span]]] = [:]
    private var canonicalBooks: [String: String] = [:]
    private func address(_ text: String) -> (book: String, chapter: Int, verse: Int)? {
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return nil }
        let numbers = parts[1].split(separator: ":")
        guard numbers.count == 2, let chapter = Int(numbers[0]), let verse = Int(numbers[1]),
              (1...1000).contains(chapter), (1...1000).contains(verse) else { return nil }
        let sourceBook = String(parts[0])
        let book: String
        if let saved = canonicalBooks[sourceBook] { book = saved }
        else {
            guard let query = LegacyPassageQuery.sourceReference(text) else { return nil }
            book = query.sourceBookKey; canonicalBooks[sourceBook] = book
        }
        return (book, chapter, verse)
    }
    func matching(_ resources: [LibraryResource], reference: String) async throws -> [String] {
        guard let query = LegacyPassageQuery.sourceReference(reference) else { return [] }
        var matches: [String] = []
        for resource in resources {
            try Task.checkCancellation()
            guard let url = LibronNativeReader.location(resource) else { continue }
            let books: [String: [Span]]
            if let saved = coverage[url] { books = saved }
            else {
                // Only the explicit owner index is authoritative. Old stores
                // may have bible_v1 rows that are merely citations in prose.
                let db = try LibronNativeDatabase(url)
                guard let data = try db.get("commentary-index") else { coverage[url] = [:]; continue }
                let entries = try JSONDecoder().decode([StoredRange].self, from: data)
                guard entries.count <= 300_000 else { throw LibronError.invalid("Commentary index exceeds limit") }
                let count = try await LibronNativeReader.shared.header(resource)?.sectionCount ?? 0
                var indexed: [String: [Span]] = [:]
                for entry in entries {
                    guard (0..<count).contains(entry.ordinal), let start = address(entry.start), let end = address(entry.end),
                          start.book == end.book, (start.chapter, start.verse) <= (end.chapter, end.verse) else { continue }
                    indexed[start.book, default: []].append(.init(chapter: start.chapter, verse: start.verse, endChapter: end.chapter, endVerse: end.verse))
                }
                books = indexed; coverage[url] = books
            }
            if books[query.sourceBookKey]?.contains(where: { passage in
                (passage.chapter, passage.verse) <= (query.chapter, query.verse) &&
                (query.chapter, query.verse) <= (passage.endChapter, passage.endVerse)
            }) == true { matches.append(resource.id) }
        }
        return matches
    }
}

struct CommentaryCoverageRequest: Hashable {
    var reference: String?
    var resources: [LibraryResource]
}

@MainActor extension StudyWorkspace {
    func commentaryChoices(for reader: ReaderSession) -> [LibraryResource] {
        guard reader.commentaryChoicesReference == reader.commentaryReference else { return [] }
        return commentaryResources.filter { reader.commentaryChoiceIDs.contains($0.id) }
    }
    func cycleCommentary(_ reader: ReaderSession, backwards: Bool = false) {
        let choices = commentaryChoices(for: reader)
        guard reader.isCommentary, choices.count > 1, !reader.isLoading else { return }
        let current = choices.firstIndex { $0.id == reader.resource.id }
        let index = current.map { ($0 + (backwards ? choices.count-1 : 1)) % choices.count }
            ?? (backwards ? choices.count-1 : 0)
        openCommentary(choices[index], replacing: reader)
    }
}
