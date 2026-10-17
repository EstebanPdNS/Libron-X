import AppKit
import LibronixCore

/// The immutable SQLite body remains available in the package. Display uses
/// native rich text; plain text and verse anchors share the exact UTF-16 body.
enum ESwordReader {
    static func read(_ resource: LibraryResource, _ request: ReaderDestination) async throws -> ReaderPage {
        if request.endReference != nil { throw RebuildError.invalidPassagePart }
        let source = try ESwordResource.page(resource.location, ordinal: request.ordinal, reference: request.reference)
        return try await project(source, request: request)
    }
    static func find(_ resource: LibraryResource, _ request: ReaderFindRequest) async throws -> ReaderFindMatch? {
        guard !request.query.isEmpty else { return nil }
        let initial = try await read(resource, .init(ordinal: request.ordinal))
        let forward = request.direction == .forward
        let position = min(max(0, request.position), initial.text.utf16.count)
        func search(_ page: ReaderPage, from: Int, to: Int, wrapped: Bool) throws -> ReaderFindMatch? {
            guard let range = try ReaderFindSource.match(page.text, query: request.query, range: .init(location: from, length: to - from), direction: request.direction, options: request.options) else { return nil }
            return .init(ordinal: page.destination.ordinal, range: range, fingerprint: LibrarySearchService.textFingerprint(page.text), wrapped: wrapped)
        }
        if let match = try search(initial, from: forward ? position : 0, to: forward ? initial.text.utf16.count : position, wrapped: false) { return match }
        let rest = forward ? Array((request.ordinal + 1)..<initial.sectionCount) : Array((0..<request.ordinal).reversed())
        let wrapped = forward ? Array(0..<request.ordinal) : Array(((request.ordinal + 1)..<initial.sectionCount).reversed())
        for (ordinals, didWrap) in [(rest, false), (request.options.wraps ? wrapped : [], true)] {
            for ordinal in ordinals {
                try Task.checkCancellation()
                let page = try await read(resource, .init(ordinal: ordinal))
                if let match = try search(page, from: 0, to: page.text.utf16.count, wrapped: didWrap) { return match }
            }
        }
        return request.options.wraps ? try search(initial, from: forward ? 0 : position, to: forward ? position : initial.text.utf16.count, wrapped: true) : nil
    }
    @MainActor static func project(_ source: ESwordPage, request: ReaderDestination) throws -> ReaderPage {
        let result = NSMutableAttributedString(string: "")
        var anchors: [LegacyReferenceAnchor] = []
        for entry in source.entries {
            try Task.checkCancellation()
            if let reference = entry.reference {
                anchors.append(.init(reference: reference, flags: 0, dataTypeCode: 0, characterOffset: result.length, decodedOffset: 0))
                result.append(NSAttributedString(string: entry.title + " ", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
            }
            let raw = entry.body
            let value: NSAttributedString
            if raw.hasPrefix("{\\rtf") {
                guard let data = raw.data(using: .utf8), let imported = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else { throw LibronError.invalid("e-Sword: unsupported RTF body") }
                value = imported
            } else {
                // Strip active/remote surfaces before AppKit's HTML import.
                var html = raw
                for pattern in [#"(?is)<(script|style|iframe|object|embed|video|audio|svg|math)\b[^>]*>.*?</\1\s*>"#,
                                #"(?is)<(?:img|link|base|meta|input|form)\b[^>]*>"#,
                                #"(?is)\sstyle\s*=\s*(?:"[^"]*(?:url\s*\(|@import|expression\s*\()[^"]*"|'[^']*(?:url\s*\(|@import|expression\s*\()[^']*')"#,
                                #"(?is)\s(?:src|srcset|background|on[a-z]+)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#] {
                    html = html.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                }
                // Keep inline style only when it contains no resource-loading CSS.
                // Red-letter font tags and semantic bold/italic/sup remain intact.
                let wrapped = "<html><head><meta charset='UTF-8'></head><body>" + html + "</body></html>"
                guard let imported = try? NSAttributedString(data: Data(wrapped.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else { throw LibronError.invalid("e-Sword: unsupported HTML body") }
                value = imported
            }
            result.append(value)
            if !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n")) }
        }
        let text = result.string
        let rtf = try result.data(from: NSRange(location: 0, length: result.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let content = LegacySectionContent.imported(text: text, ordinal: source.ordinal, anchors: anchors, rtf: rtf)
        let selection: NSRange?
        if let reference = request.reference, let query = LegacyPassageQuery.sourceReference(reference),
           let anchor = anchors.first(where: { $0.reference.flatMap(LegacyPassageQuery.sourceReference)?.normalizedKey == query.normalizedKey }) {
            selection = .init(location: anchor.characterOffset, length: 0)
        } else if request.reference != nil { throw RebuildError.referenceNotFound }
        else { selection = nil }
        return ReaderPage(destination: .init(ordinal: source.ordinal, reference: request.reference), text: text, sectionCount: source.contents.count,
            entries: source.contents.enumerated().map { .init(id: $0.offset, ordinal: $0.offset, title: $0.element) }, selection: selection, content: content)
    }
}
