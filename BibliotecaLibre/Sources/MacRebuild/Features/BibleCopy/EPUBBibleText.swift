import Foundation
import LibronixCore

/// Reads only explicit verse anchors from structured XHTML. Ancillary study
/// panels and reference markers are excluded from the Bible-text projection.
struct EPUBBibleText {
    static func read(book: LibronixOEBBook, entries: [EPUBBibleDirectory.Entry]) throws -> [String: String] {
        let requested = Set(entries.map(\.fragment))
        let paths = Set(entries.map(\.path))
        let parser = VerseTextParser(requested: requested)
        for path in book.directory.files where paths.contains(path) {
            try Task.checkCancellation()
            guard let data = book.members[path] else { throw BibleCopyError.incompleteSource }
            parser.beginFile()
            let xml = XMLParser(data: data)
            xml.shouldResolveExternalEntities = false
            xml.delegate = parser
            guard xml.parse() else { throw BibleCopyError.unsupportedContent }
        }
        try book.verifySource()
        guard requested.allSatisfy({ parser.text[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
            throw BibleCopyError.incompleteSource
        }
        return parser.text
    }
}

private final class VerseTextParser: NSObject, XMLParserDelegate {
    let requested: Set<String>
    var text: [String: String] = [:]
    private var current: String?
    private var depth = 0
    private var ignoredUntil: Int?
    private var paragraphUntil: Int?
    private var skipLeadingNumber = false
    init(requested: Set<String>) { self.requested = requested }
    func beginFile() { current = nil; depth = 0; ignoredUntil = nil; paragraphUntil = nil; skipLeadingNumber = false }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        depth += 1
        guard ignoredUntil == nil else { return }
        let name = elementName.lowercased(), id = attributes["id"] ?? "", css = attributes["class"] ?? ""
        let classes = Set(css.split(whereSeparator: \.isWhitespace).map(String.init))
        if !classes.isDisjoint(with: ["sidebar", "idx", "notes", "footnotes"]) {
            ignoredUntil = depth; return
        }
        let anchor = id.utf8.count == 9 && id.first == "v" && id.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
        if anchor {
            current = requested.contains(id) ? id : nil
            if current != nil { text[id] = "" }
            if name == "a" || name == "span" { ignoredUntil = depth; return }
            skipLeadingNumber = name == "p"
        }
        if name == "p" {
            let allowed = css.isEmpty || ["pf", "paft", "pcon", "psec1"].contains(css) ||
                ["sl", "bq", "lt", "ul"].contains(where: { css.hasPrefix($0) })
            if allowed {
                paragraphUntil = depth
                if let current, !(text[current] ?? "").isEmpty { text[current, default: ""] += "\n" }
            }
        }
        if name == "a" {
            let target = attributes["href"] ?? ""
            let marker = classes.contains("fnref") || classes.contains("enref") ||
                (id.hasSuffix("r") && (id.hasPrefix("fn") || id.hasPrefix("gt"))) ||
                target.contains("#fn") || target.contains("#gt")
            if marker { ignoredUntil = depth; return }
        }
        if name == "sup", skipLeadingNumber { ignoredUntil = depth; skipLeadingNumber = false }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard ignoredUntil == nil, paragraphUntil != nil, let current else { return }
        text[current, default: ""] += string
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { skipLeadingNumber = false }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if ignoredUntil == depth { ignoredUntil = nil }
        if paragraphUntil == depth { paragraphUntil = nil }
        depth -= 1
    }
}
