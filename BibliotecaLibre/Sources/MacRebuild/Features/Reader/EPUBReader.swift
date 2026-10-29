import Foundation
import LibronixCore

actor EPUBReader {
    static let shared = EPUBReader()
    private var cached: [URL: EPUBArchive] = [:]
    func prepare(_ url: URL) throws -> EPUBArchive {
        if let value = cached[url], (try? value.book.verifySource()) != nil { return value }
        let value = try EPUBArchive(url)
        let size = value.book.members.values.reduce(0) { $0 + $1.count }
        let currentSize = cached.values.reduce(0) { total, archive in total + archive.book.members.values.reduce(0) { $0 + $1.count } }
        let budget = 160 * 1024 * 1024
        if cached.count >= 4 || currentSize + size > budget { cached.removeAll() }
        if size <= budget { cached[url] = value }
        return value
    }
    static func read(_ resource: LibraryResource, _ request: ReaderDestination) async throws -> ReaderPage {
        let archive = try await shared.prepare(resource.location), book = archive.book
        guard book.directory.articles.indices.contains(request.ordinal) else { throw RebuildError.referenceNotFound }
        let article = book.directory.articles[request.ordinal]
        return ReaderPage(destination: request, text: "", sectionCount: book.directory.articles.count,
            entries: book.directory.articles.map { .init(id: $0.ordinal, ordinal: $0.ordinal, title: $0.title, depth: $0.depth) },
            oeb: .init(book: book, url: book.url(path: article.path, fragment: request.reference)))
    }
}
