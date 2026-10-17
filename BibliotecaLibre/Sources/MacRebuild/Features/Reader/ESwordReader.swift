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
        if source.entries.count > 1, source.entries.contains(where: { $0.body.contains("<") || $0.body.contains("&") }), source.entries.allSatisfy({ $0.reference != nil && !$0.body.hasPrefix("{\\rtf") }),
           let batched = try batchHTML(source,request:request) { return batched }
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
            if !raw.contains("<"), !raw.contains("&"), !raw.hasPrefix("{\\rtf") {
                value = NSAttributedString(string:raw,attributes:[.font:NSFont(name:"TimesNewRomanPSMT",size:12) ?? NSFont.systemFont(ofSize:12)])
            } else if raw.hasPrefix("{\\rtf") {
                guard let data = raw.data(using: .utf8), let imported = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else { throw LibronError.invalid("e-Sword: unsupported RTF body") }
                value = imported
            } else {
                let wrapped = ImportFormattingPipeline.html(raw).html
                guard let imported = try? NSAttributedString(data: Data(wrapped.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else { throw LibronError.invalid("e-Sword: unsupported HTML body") }
                value = imported
            }
            result.append(ImportedTypography.normalize(value, repairCharacters: true).text)
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
    /// Parse a chapter once while retaining a verified UTF-16 anchor for every
    /// verse. If malformed markup hides a marker, use the isolated entry path.
    @MainActor private static func batchHTML(_ source: ESwordPage, request: ReaderDestination) throws -> ReaderPage? {
        let token = "LIBRONVERSE"+UUID().uuidString.replacingOccurrences(of:"-",with:"")
        let markers = source.entries.indices.map { token+String($0)+"END" }
        let html = zip(source.entries,markers).map { entry,marker in
            "<div>"+marker+"<b>"+entry.title+" </b>"+entry.body+"</div>"
        }.joined()
        let wrapped = ImportFormattingPipeline.html(html).html
        guard let parsed = try? NSAttributedString(data:Data(wrapped.utf8),options:[.documentType:NSAttributedString.DocumentType.html,.characterEncoding:String.Encoding.utf8.rawValue],documentAttributes:nil) else { return nil }
        let value = ImportedTypography.normalize(parsed,repairCharacters:true).text
        let positions = markers.map { (value.string as NSString).range(of:$0) }
        guard positions.allSatisfy({ $0.location != NSNotFound }), zip(positions,positions.dropFirst()).allSatisfy({ $0.location < $1.location }) else { return nil }
        for range in positions.reversed() { value.deleteCharacters(in:range) }
        var removed = 0
        let anchors: [LegacyReferenceAnchor] = zip(source.entries,positions).map { entry,range in
            defer { removed += range.length }
            return .init(reference:entry.reference,flags:0,dataTypeCode:0,characterOffset:range.location-removed,decodedOffset:0)
        }
        let text = value.string
        let rtf = try value.data(from:.init(location:0,length:value.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
        var selection: NSRange?
        if let reference = request.reference {
            guard let query = LegacyPassageQuery.sourceReference(reference), let anchor = anchors.first(where: { $0.reference.flatMap(LegacyPassageQuery.sourceReference)?.normalizedKey == query.normalizedKey }) else { throw RebuildError.referenceNotFound }
            selection = .init(location:anchor.characterOffset,length:0)
        }
        return .init(destination:.init(ordinal:source.ordinal,reference:request.reference),text:text,sectionCount:source.contents.count,
            entries:source.contents.enumerated().map { .init(id:$0.offset,ordinal:$0.offset,title:$0.element) },selection:selection,
            content:.imported(text:text,ordinal:source.ordinal,anchors:anchors,rtf:rtf))
    }

}
