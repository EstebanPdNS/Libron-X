import Foundation
import LibronixCore

actor EPUBReader {
    static let shared = EPUBReader()
    private var cached: [URL: EPUBArchive] = [:]
    func prepare(_ url: URL) throws -> EPUBArchive {
        if let value = cached[url], (try? value.book.verifySource()) != nil { return value }
        let value = try EPUBArchive(url)
        if cached.count >= 4 { cached.removeAll() }
        cached[url] = value; return value
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
