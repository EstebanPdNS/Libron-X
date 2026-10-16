import Foundation
import LibronixCore

/// Article boundaries come from the original OEB fragments in the rendered DOM.
/// Match ranges stay in the full physical page, exactly like visible selection.
enum ReaderOEBFind {
    typealias Projection = @Sendable (LibronixOEBBook, String, ReaderOEBViewport) async throws -> ReaderOEBTextPage
    static func find(_ resource: LibraryResource, _ request: ReaderFindRequest) async throws -> ReaderFindMatch? {
        let book = try await LibronixOEBService.shared.prepare(resource.location)
        return try await find(book: book, request: request) { book, path, viewport in
            try await ReaderOEBTextSource.shared.read(book: book, path: path, viewport: viewport)
        }
    }
    static func find(book: LibronixOEBBook, request: ReaderFindRequest, projection: Projection) async throws -> ReaderFindMatch? {
        guard !request.query.isEmpty else { return nil }
        let entries = book.directory.articles
        guard entries.indices.contains(request.ordinal) else { throw RebuildError.referenceNotFound }
        try Task.checkCancellation(); try book.verifySource()
        let viewport = request.oebViewport ?? .init()
        func read(_ ordinal: Int) async throws -> ReaderOEBTextPage {
            try Task.checkCancellation(); try book.verifySource()
            let result = try await projection(book, entries[ordinal].path, viewport)
            try Task.checkCancellation(); try book.verifySource()
            guard result.path.lowercased() == entries[ordinal].path.lowercased(), result.articleRanges[ordinal] != nil else { throw LibronixBookError.invalidDirectory }
            return result
        }
        let current = try await read(request.ordinal)
        let requestedSpan = try span(current, ordinal: request.ordinal)
        // A selection can be in another article on the same physical page.
        // An initial zero caret for a fragment-open remains at that fragment.
        var ordinal = request.ordinal
        if request.position > 0 || requestedSpan.location == 0 {
            if let owner = current.articleRanges.filter({ NSLocationInRange(request.position, $0.value) }).min(by: { $0.key < $1.key })?.key { ordinal = owner }
        }
        let currentSpan = try span(current, ordinal: ordinal)
        let position = min(NSMaxRange(currentSpan), max(currentSpan.location, request.position))
        func search(_ page: ReaderOEBTextPage, ordinal: Int, from: Int, to: Int, wrapped: Bool) throws -> ReaderFindMatch? {
            try Task.checkCancellation()
            guard let range = try ReaderFindSource.match(page.text, query: request.query,
                range: NSRange(location: from, length: to - from), direction: request.direction, options: request.options) else { return nil }
            try book.verifySource()
            return ReaderFindMatch(ordinal: ordinal, range: range, fingerprint: page.fingerprint, wrapped: wrapped, oebProjection: page)
        }
        let forward = request.direction == .forward
        if let result = try search(current, ordinal: ordinal, from: forward ? position : currentSpan.location,
            to: forward ? NSMaxRange(currentSpan) : position, wrapped: false) { return result }
        let first = forward ? Array((ordinal + 1)..<entries.count) : Array((0..<ordinal).reversed())
        for next in first {
            let page = try await read(next), range = try span(page, ordinal: next)
            if let result = try search(page, ordinal: next, from: range.location, to: NSMaxRange(range), wrapped: false) { return result }
        }
        guard request.options.wraps else { try book.verifySource(); return nil }
        let second = forward ? Array(0..<ordinal) : Array(((ordinal + 1)..<entries.count).reversed())
        for next in second {
            let page = try await read(next), range = try span(page, ordinal: next)
            if let result = try search(page, ordinal: next, from: range.location, to: NSMaxRange(range), wrapped: true) { return result }
        }
        let result = try search(current, ordinal: ordinal, from: forward ? currentSpan.location : position,
            to: forward ? position : NSMaxRange(currentSpan), wrapped: true)
        try Task.checkCancellation(); try book.verifySource(); return result
    }
    private static func span(_ page: ReaderOEBTextPage, ordinal: Int) throws -> NSRange {
        guard let range = page.articleRanges[ordinal], range.location >= 0, range.length >= 0,
              range.location <= page.text.utf16.count, range.length <= page.text.utf16.count - range.location else { throw LibronixBookError.invalidDirectory }
        return range
    }
}
