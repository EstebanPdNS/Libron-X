import Foundation
import LibronixCore

struct ReaderFindOptions: Equatable, Sendable {
    var caseSensitive = false
    var diacriticSensitive = true
    var wholeWords = false
    var wraps = true
}
enum ReaderFindDirection: Sendable { case forward, backward }
struct ReaderFindRequest: Sendable {
    var query: String
    var ordinal: Int
    var position: Int
    var direction: ReaderFindDirection = .forward
    var options = ReaderFindOptions()
    var oebViewport: ReaderOEBViewport? = nil
}
struct ReaderFindMatch: Sendable {
    let ordinal: Int
    let range: NSRange
    let fingerprint: String
    let wrapped: Bool
    var oebProjection: ReaderOEBTextPage? = nil
}
enum ReaderFindStatus: Equatable { case idle, searching, found(wrapped: Bool), notFound, failed(String) }

/// Literal Find is independent of the indexed query language. Positions are
/// ranges in the decoded visible body, never inferred native AOL coordinates.
enum ReaderFindSource {
    static func find(_ resource: LibraryResource, _ request: ReaderFindRequest) async throws -> ReaderFindMatch? {
        if let header = try await LibronNativeReader.shared.header(resource) {
            guard !request.query.isEmpty else { return nil }
            if header.profile == "html" {
                let page = try await LibronNativeReader.shared.read(resource,.init(ordinal:request.ordinal))
                guard let html = page.oeb else { throw RebuildError.unsupportedFormat }
                return try await ReaderOEBFind.find(book:html.book,request:request) { book,path,viewport in
                    try await ReaderOEBTextSource.shared.read(book:book,path:path,viewport:viewport)
                }
            }
            guard (0..<header.sectionCount).contains(request.ordinal) else { throw RebuildError.referenceNotFound }
            let forward = request.direction == .forward
            let current = try await LibronNativeReader.shared.read(resource,.init(ordinal:request.ordinal))
            let position = min(max(0,request.position),current.text.utf16.count)
            func search(_ page: ReaderPage, from: Int, to: Int, wrapped: Bool) throws -> ReaderFindMatch? {
                guard let range = try match(page.text,query:request.query,range:.init(location:from,length:to-from),direction:request.direction,options:request.options) else { return nil }
                return .init(ordinal:page.destination.ordinal,range:range,fingerprint:LibrarySearchService.textFingerprint(page.text),wrapped:wrapped)
            }
            if let found = try search(current,from:forward ? position : 0,to:forward ? current.text.utf16.count : position,wrapped:false) { return found }
            let first = forward ? Array((request.ordinal+1)..<header.sectionCount) : Array((0..<request.ordinal).reversed())
            for ordinal in first {
                try Task.checkCancellation()
                let page = try await LibronNativeReader.shared.read(resource,.init(ordinal:ordinal))
                if let found = try search(page,from:0,to:page.text.utf16.count,wrapped:false) { return found }
            }
            guard request.options.wraps else { return nil }
            let second = forward ? Array(0..<request.ordinal) : Array(((request.ordinal+1)..<header.sectionCount).reversed())
            for ordinal in second {
                try Task.checkCancellation()
                let page = try await LibronNativeReader.shared.read(resource,.init(ordinal:ordinal))
                if let found = try search(page,from:0,to:page.text.utf16.count,wrapped:true) { return found }
            }
            return try search(current,from:forward ? 0 : position,to:forward ? position : current.text.utf16.count,wrapped:true)
        }
        if resource.format == .libronixOEB || resource.format == .epub { return try await ReaderOEBFind.find(resource, request) }
        if resource.format == .libronDictionary {
            let page = try LibronDictionaryDatabase.page(resource.location, ordinal: request.ordinal)
            let length = page.body.utf16.count, position = min(max(0, request.position), length)
            let forward = request.direction == .forward
            func search(_ from: Int, _ to: Int, wrapped: Bool) throws -> ReaderFindMatch? {
                guard let range = try match(page.body, query: request.query, range: .init(location: from, length: to - from), direction: request.direction, options: request.options) else { return nil }
                return .init(ordinal: page.ordinal, range: range, fingerprint: LibrarySearchService.textFingerprint(page.body), wrapped: wrapped)
            }
            if let result = try search(forward ? position : 0, forward ? length : position, wrapped: false) { return result }
            return request.options.wraps ? try search(forward ? 0 : position, forward ? position : length, wrapped: true) : nil
        }
        if resource.format == .eSwordSQLite { return try await ESwordReader.find(resource, request) }
        if resource.format == .libronixLLS {
            let before = try LegacyGraphicsService.fileStamp(resource.location)
            let inner = try await LibronixBookService.shared.prepare(resource)
            let match = try await find(inner, request)
            guard try LegacyGraphicsService.fileStamp(resource.location) == before else { throw LibronixBookError.sourceChanged }
            return match
        }
        guard resource.format == .legacyLSF else { throw RebuildError.unsupportedFormat }
        guard !request.query.isEmpty else { return nil }
        let before = try LegacyGraphicsService.fileStamp(resource.location)
        let service = LegacyContentService()
        let index = try await service.inspect(resource.location)
        guard index.sections.indices.contains(request.ordinal) else { throw LegacyContentError.sectionNotFound(request.ordinal) }
        let current = try await service.read(resource.location, ordinal: request.ordinal)
        let position = min(max(0, request.position), current.plainText.utf16.count)
        func search(_ content: LegacySectionContent, from: Int, to: Int, wrapped: Bool) throws -> ReaderFindMatch? {
            let text = content.plainText
            guard let range = try match(text, query: request.query, range: NSRange(location: from, length: to - from),
                                        direction: request.direction, options: request.options) else { return nil }
            return ReaderFindMatch(ordinal: content.descriptor.ordinal, range: range,
                fingerprint: LibrarySearchService.textFingerprint(text), wrapped: wrapped)
        }
        func verify(_ result: ReaderFindMatch?) throws -> ReaderFindMatch? {
            try Task.checkCancellation()
            guard try LegacyGraphicsService.fileStamp(resource.location) == before else { throw LegacyIndicesError.sourceChanged }
            return result
        }
        let forward = request.direction == .forward
        if let result = try search(current, from: forward ? position : 0,
                                   to: forward ? current.plainText.utf16.count : position, wrapped: false) { return try verify(result) }
        let firstPass: [Int] = forward
            ? Array((request.ordinal + 1)..<index.sections.count)
            : Array((0..<request.ordinal).reversed())
        for ordinal in firstPass {
            try Task.checkCancellation()
            let article = try await service.read(resource.location, ordinal: ordinal)
            if let result = try search(article, from: 0, to: article.plainText.utf16.count, wrapped: false) { return try verify(result) }
        }
        guard request.options.wraps else { return try verify(nil) }
        let secondPass: [Int] = forward
            ? Array(0..<request.ordinal)
            : Array(((request.ordinal + 1)..<index.sections.count).reversed())
        for ordinal in secondPass {
            try Task.checkCancellation()
            let article = try await service.read(resource.location, ordinal: ordinal)
            if let result = try search(article, from: 0, to: article.plainText.utf16.count, wrapped: true) { return try verify(result) }
        }
        if let result = try search(current, from: forward ? 0 : position,
                                   to: forward ? position : current.plainText.utf16.count, wrapped: true) { return try verify(result) }
        return try verify(nil)
    }

    static func match(_ text: String, query: String, range: NSRange, direction: ReaderFindDirection,
                      options: ReaderFindOptions) throws -> NSRange? {
        guard !query.isEmpty else { return nil }
        let source = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= source.length,
              range.length <= source.length - range.location else { return nil }
        var comparison: NSString.CompareOptions = []
        if !options.caseSensitive { comparison.insert(.caseInsensitive) }
        if !options.diacriticSensitive { comparison.insert(.diacriticInsensitive) }
        if direction == .backward { comparison.insert(.backwards) }
        var wordStarts = Set<Int>(), wordEnds = Set<Int>()
        if options.wholeWords {
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, word, _, _ in
                let interval = NSRange(word, in: text)
                wordStarts.insert(interval.location); wordEnds.insert(NSMaxRange(interval))
            }
        }
        var remaining = range
        while remaining.length > 0 {
            try Task.checkCancellation()
            let found = source.range(of: query, options: comparison, range: remaining, locale: nil)
            guard found.location != NSNotFound, found.length > 0 else { return nil }
            let complete = source.rangeOfComposedCharacterSequences(for: found)
            if (!options.wholeWords || (wordStarts.contains(complete.location) && wordEnds.contains(NSMaxRange(complete)))),
               complete.location >= range.location, NSMaxRange(complete) <= NSMaxRange(range) { return complete }
            if direction == .forward {
                let end = NSMaxRange(remaining), next = max(NSMaxRange(complete), NSMaxRange(found))
                remaining = NSRange(location: next, length: max(0, end - next))
            } else { remaining.length = max(0, min(found.location, complete.location) - remaining.location) }
        }
        return nil
    }
}
