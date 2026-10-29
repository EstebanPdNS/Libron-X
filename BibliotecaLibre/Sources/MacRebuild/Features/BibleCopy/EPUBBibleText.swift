import Foundation
import LibronixCore

/// Typed projection of explicit XHTML verse anchors. Study panels are not
/// Scripture; note references keep their target for optional footnote output.
struct EPUBBibleText {
    struct Piece: Sendable {
        let text: String
        let bold: Bool
        let italic: Bool
        let underline: Bool
        let strikeout: Bool
        let smallCaps: Bool
        let noteTarget: String?
        let sourcePath: String
        let paragraph: Int
        var noteKey: String { sourcePath + "\0" + (noteTarget ?? "") }
    }
    static func read(book: LibronixOEBBook, entries: [EPUBBibleDirectory.Entry]) throws -> [String: [Piece]] {
        let requested = Set(entries.map(\.fragment)), paths = Set(entries.map(\.path))
        let delegate = VerseTextParser(requested: requested)
        for path in book.directory.files where paths.contains(path) {
            try Task.checkCancellation()
            guard let data = book.members[path] else { throw BibleCopyError.incompleteSource }
            delegate.beginFile(path)
            let xml = XMLParser(data: data); xml.shouldResolveExternalEntities = false; xml.delegate = delegate
            guard xml.parse() else { throw BibleCopyError.unsupportedContent }
        }
        try book.verifySource()
        guard !delegate.unsupported else { throw BibleCopyError.unsupportedContent }
        guard requested.allSatisfy({ id in
            delegate.verses[id]?.contains { $0.noteTarget == nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
        }) else { throw BibleCopyError.incompleteSource }
        return delegate.verses
    }
}

private final class VerseTextParser: NSObject, XMLParserDelegate {
    let requested: Set<String>
    var verses: [String: [EPUBBibleText.Piece]] = [:]
    var unsupported = false
    private var current: String?
    private var path = ""
    private var depth = 0
    private var ignoredUntil: Int?
    private var paragraphUntil: Int?
    private var paragraph = 0
    private var skipLeadingNumber = false
    private var verseMarker: (depth: Int, hasText: Bool)?
    private var note: (depth: Int, target: String, marker: String)?
    private var styles: [(depth: Int, bold: Bool, italic: Bool, underline: Bool, strikeout: Bool, smallCaps: Bool)] = []
    init(requested: Set<String>) { self.requested = requested }
    func beginFile(_ path: String) {
        self.path = path; current = nil; depth = 0; ignoredUntil = nil; paragraphUntil = nil
        skipLeadingNumber = false; verseMarker = nil; note = nil; styles.removeAll()
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        depth += 1
        guard ignoredUntil == nil, note == nil else { return }
        let name = elementName.lowercased(), id = attributes["id"] ?? "", css = attributes["class"] ?? ""
        let classes = Set(css.split(whereSeparator: \.isWhitespace).map(String.init))
        if !classes.isDisjoint(with: ["sidebar", "idx", "notes", "footnotes"]) { ignoredUntil = depth; return }
        if name == "script" || name == "style" { ignoredUntil = depth; return }
        let anchor = id.utf8.count == 9 && id.first == "v" && id.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
        if anchor {
            current = requested.contains(id) ? id : nil
            if current != nil { verses[id] = [] }
            if name == "a" || name == "span" { verseMarker = (depth, false); ignoredUntil = depth; return }
            skipLeadingNumber = name == "p"
        }
        if name == "p" {
            let allowed = css.isEmpty || ["pf", "paft", "pcon", "psec1"].contains(css) || ["sl", "bq", "lt", "ul"].contains(where: { css.hasPrefix($0) })
            if allowed { paragraph += 1; paragraphUntil = depth }
        }
        if name == "a" {
            let target = attributes["href"] ?? ""
            let marker = classes.contains("fnref") || classes.contains("enref") ||
                (id.hasSuffix("r") && (id.hasPrefix("fn") || id.hasPrefix("gt"))) || target.contains("#fn") || target.contains("#gt")
            if marker { note = (depth, target, ""); return }
            if current != nil && paragraphUntil != nil { unsupported = true }
        }
        if current != nil && paragraphUntil != nil && ["img", "object", "table", "svg"].contains(name) { unsupported = true }
        if name == "br", let current, paragraphUntil != nil {
            let style = styles.last
            verses[current, default: []].append(.init(text: "\n", bold: style?.bold ?? false, italic: style?.italic ?? false,
                underline: style?.underline ?? false, strikeout: style?.strikeout ?? false, smallCaps: style?.smallCaps ?? false, noteTarget: nil, sourcePath: path, paragraph: paragraph))
        }
        if name == "sup", skipLeadingNumber { ignoredUntil = depth; skipLeadingNumber = false; return }
        if current != nil && paragraphUntil != nil {
            if attributes["style"] != nil || ["sup", "sub", "font"].contains(name) { unsupported = true }
            if name == "span" && !classes.isSubset(of: ["red", "red-i", "red-b", "first", "tetr", "sm"]) { unsupported = true }
        }
        let parent = styles.last
        styles.append((depth, (parent?.bold ?? false) || name == "b" || name == "strong" || classes.contains("red-b"),
                       (parent?.italic ?? false) || name == "i" || name == "em" || classes.contains("red-i"),
                       (parent?.underline ?? false) || name == "u", (parent?.strikeout ?? false) || name == "s" || name == "del",
                       (parent?.smallCaps ?? false) || classes.contains("sm")))
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if note != nil { note?.marker += string; return }
        if ignoredUntil != nil {
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { verseMarker?.hasText = true }
            return
        }
        guard ignoredUntil == nil, paragraphUntil != nil, let current else { return }
        let style = styles.last
        verses[current, default: []].append(.init(text: string, bold: style?.bold ?? false, italic: style?.italic ?? false,
            underline: style?.underline ?? false, strikeout: style?.strikeout ?? false, smallCaps: style?.smallCaps ?? false, noteTarget: nil, sourcePath: path, paragraph: paragraph))
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { skipLeadingNumber = false }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let marker = verseMarker, marker.depth == depth { skipLeadingNumber = !marker.hasText; verseMarker = nil }
        if let captured = note, captured.depth == depth {
            if let current, paragraphUntil != nil {
                verses[current, default: []].append(.init(text: captured.marker, bold: false, italic: false, underline: false,
                    strikeout: false, smallCaps: false, noteTarget: captured.target, sourcePath: path, paragraph: paragraph))
            }
            note = nil
        }
        if ignoredUntil == depth { ignoredUntil = nil }
        if paragraphUntil == depth { paragraphUntil = nil }
        if styles.last?.depth == depth { styles.removeLast() }
        depth -= 1
    }
}

extension EPUBBibleText {
    struct Note: Sendable { let id: String; let text: String; let ordinal: Int }
    static func footnotes(book: LibronixOEBBook, pieces: [Piece]) throws -> [String: Note] {
        struct Request { let key: String; let path: String; let fragment: String; let ordinal: Int }
        let prefix = "/epub-root/", root = URL(fileURLWithPath: "/epub-root/", isDirectory: true)
        var requests: [Request] = []
        for piece in pieces where piece.noteTarget != nil {
            try Task.checkCancellation()
            let target = piece.noteTarget!
            guard let parts = URLComponents(string: target), parts.scheme == nil, parts.host == nil, parts.query == nil,
                  let fragment = parts.fragment, !fragment.isEmpty,
                  let decoded = parts.percentEncodedPath.removingPercentEncoding, !decoded.hasPrefix("/") else {
                throw BibleCopyError.unsupportedContent
            }
            let base = root.appendingPathComponent(piece.sourcePath).deletingLastPathComponent()
            let resolved = (decoded.isEmpty ? root.appendingPathComponent(piece.sourcePath) : base.appendingPathComponent(decoded)).standardizedFileURL.path
            guard resolved.hasPrefix(prefix) else { throw BibleCopyError.missingBoundary }
            let path = String(resolved.dropFirst(prefix.count))
            guard book.members[path] != nil, let ordinal = book.directory.files.firstIndex(of: path) else { throw BibleCopyError.missingBoundary }
            requests.append(.init(key: piece.noteKey, path: path, fragment: fragment, ordinal: ordinal))
        }
        var result: [String: Note] = [:]
        for (path, group) in Dictionary(grouping: requests, by: \.path) {
            try Task.checkCancellation()
            guard let data = book.members[path] else { throw BibleCopyError.missingBoundary }
            let delegate = NoteTextParser(ids: Set(group.map(\.fragment))), xml = XMLParser(data: data)
            xml.shouldResolveExternalEntities = false; xml.delegate = delegate
            guard xml.parse(), !delegate.duplicate else { throw BibleCopyError.incompleteSource }
            for request in group {
                guard let value = delegate.notes[request.fragment]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                    throw BibleCopyError.incompleteSource
                }
                result[request.key] = .init(id: path + "#" + request.fragment, text: value, ordinal: request.ordinal)
            }
        }
        try book.verifySource()
        return result
    }
}

private final class NoteTextParser: NSObject, XMLParserDelegate {
    let ids: Set<String>
    var notes: [String: String] = [:], duplicate = false
    private var depth = 0, rootDepth: Int?, skipDepth: Int?, current: String?, text = ""
    private var skippedMarker = false
    private var firstAnchorDepth: Int?, firstAnchorText = "", firstAnchorSuperscript = false
    init(ids: Set<String>) { self.ids = ids }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        depth += 1
        if let id = attributes["id"], ids.contains(id) {
            if notes[id] != nil || rootDepth != nil { duplicate = true; return }
            current = id; text = ""; rootDepth = depth; skippedMarker = false
            firstAnchorDepth = nil; firstAnchorText = ""; firstAnchorSuperscript = false; return
        }
        if firstAnchorDepth != nil { if elementName.lowercased() == "sup" { firstAnchorSuperscript = true }; return }
        guard rootDepth != nil, skipDepth == nil, !skippedMarker else { return }
        if (attributes["class"] ?? "").split(separator: " ").contains("fnnum") {
            skipDepth = depth; skippedMarker = true
        } else if elementName.lowercased() == "a" {
            firstAnchorDepth = depth; firstAnchorText = ""; firstAnchorSuperscript = false
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if firstAnchorDepth != nil { firstAnchorText += string; return }
        if rootDepth != nil && skipDepth == nil {
            text += string
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { skippedMarker = true }
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if firstAnchorDepth == depth {
            if !firstAnchorSuperscript { text += firstAnchorText }
            firstAnchorDepth = nil; skippedMarker = true
        }
        if skipDepth == depth { skipDepth = nil }
        if rootDepth == depth { if let current { notes[current] = text }; current = nil; rootDepth = nil }
        depth -= 1
    }
}
