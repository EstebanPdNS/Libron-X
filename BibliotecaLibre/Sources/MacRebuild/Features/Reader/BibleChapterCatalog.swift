import Foundation
import LibronixCore

struct BibleChapterBook: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let sourceBook: String
    let chapters: [Int]
    var firstVerses: [Int:Int]? = nil
    func reference(chapter: Int) -> String { "\(sourceBook) \(chapter):\(firstVerses?[chapter] ?? 1)" }
    func title(language: AppLanguage) -> String {
        guard let query = LegacyPassageQuery.navigationInput(reference(chapter: chapters.first ?? 1)) else { return sourceBook }
        if language == .spanish || language == .english {
            return BibleCopyReferenceNames.book(.init(query), language: language == .spanish ? .spanish : .english).full
        }
        return sourceBook
    }
    static func collect(_ labels: [String]) -> [Self] {
        var order: [String] = [], names: [String: String] = [:], chapters: [String: Set<Int>] = [:], starts: [String:[Int:Int]] = [:]
        for label in labels {
            guard let query = LegacyPassageQuery.navigationInput(label) else { continue }
            if names[query.sourceBookKey] == nil { order.append(query.sourceBookKey); names[query.sourceBookKey] = query.book }
            chapters[query.sourceBookKey, default: []].insert(query.chapter)
            starts[query.sourceBookKey,default:[:]][query.chapter] = min(starts[query.sourceBookKey]?[query.chapter] ?? query.verse,query.verse)
        }
        return order.map { .init(id: $0, sourceBook: names[$0]!, chapters: chapters[$0]!.sorted(),firstVerses:starts[$0]) }
    }
}

/// Selectors use observed source positions, not assumed chapter or canon counts.
actor BibleChapterCatalog {
    static let shared = BibleChapterCatalog()
    private var cache: [URL: [BibleChapterBook]] = [:]
    func books(in resource: LibraryResource) async throws -> [BibleChapterBook] {
        if let native = try await LibronNativeReader.shared.header(resource) {
            if resource.libron?.resourceType == "Biblia", let url = LibronNativeReader.location(resource) {
                let observed = BibleChapterBook.collect(try LibronNativeDatabase(url).chapterReferences())
                if !observed.isEmpty { return observed }
            }
            return native.chapters
        }
        if let saved = cache[resource.location] { return saved }
        let labels: [String]
        if resource.format == .eSwordSQLite, resource.libron?.resourceType == "Biblia" {
            labels = try ESwordResource.page(resource.location, ordinal: 0).contents
        } else if resource.format == .legacyLSF || resource.format == .libronixLLS {
            let inner = resource.format == .libronixLLS ? try await LibronixBookService.shared.prepare(resource) : resource
            let directory = try await LegacyContentService().directory(inner.location, indexURL: inner.indexLocation,
                allowUnavailableIndexBlocks: resource.format == .libronixLLS)
            labels = directory.entries.compactMap { entry in
                guard entry.level > 0, let label = entry.positionLabel else { return nil }
                return Self.chapterReference(label: label, title: entry.title ?? "")
            }
        } else { return [] }
        try Task.checkCancellation()
        let books = BibleChapterBook.collect(labels)
        cache[resource.location] = books
        return books
    }
    /// Explicit chapter markers and numbered chapter headings are distinct
    /// from opaque note names such as Ge.51 or FTN.GE.208.
    static func chapterReference(label: String, title: String) -> String? {
        let marker = label.components(separatedBy: ".CH")
        if marker.count == 2, let chapter = Int(marker[1]), chapter > 0, String(chapter) == marker[1],
           let query = LegacyPassageQuery.parse("\(marker[0]) \(chapter):1") { return query.displayReference }
        let words = title.split(separator: " ")
        guard words.count == 2, ["chapter", "capítulo", "psalm", "salmo"].contains(words[0].lowercased()),
              let chapter = Int(words[1]), chapter > 0 else { return nil }
        let parts = label.split(separator: ".")
        guard let last = parts.last, Int(last) == chapter, (2...3).contains(parts.count) else { return nil }
        if parts.count == 3, ["FTN", "XREF", "NOTE"].contains(parts[0].uppercased()) { return nil }
        let code = parts[parts.count - 2]
        return LegacyPassageQuery.parse("\(code) \(chapter):1")?.displayReference
    }

}
