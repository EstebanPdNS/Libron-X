import Foundation
import LibronixCore

/// Locates explicit verse anchors in the EPUB spine without inferring verses
/// from prose. Duplicate or out-of-order identifiers are not safe to copy.
struct EPUBBibleDirectory: Sendable {
    struct Entry: Sendable {
        let book: Int
        let chapter: Int
        let verse: Int
        let ordinal: Int
        let path: String
        let fragment: String
    }
    let entries: [Entry]

    init(book: LibronixOEBBook) throws {
        let scanner = AnchorScanner()
        var result: [Entry] = []
        var seen = Set<String>()
        for (ordinal, path) in book.directory.files.enumerated() {
            try Task.checkCancellation()
            guard let data = book.members[path] else { throw BibleCopyError.incompleteSource }
            scanner.anchors.removeAll(keepingCapacity: true)
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = scanner
            guard parser.parse() else { throw BibleCopyError.unsupportedContent }
            for anchor in scanner.anchors {
                let digits = anchor.dropFirst()
                let bookNumber = Int(digits.prefix(2))!
                let chapter = Int(digits.dropFirst(2).prefix(3))!
                let verse = Int(digits.suffix(3))!
                guard (1...66).contains(bookNumber), chapter > 0, verse > 0,
                      seen.insert(anchor).inserted else { throw BibleCopyError.incompleteSource }
                if let previous = result.last {
                    guard (bookNumber, chapter, verse) > (previous.book, previous.chapter, previous.verse) else {
                        throw BibleCopyError.incompleteSource
                    }
                }
                result.append(.init(book: bookNumber, chapter: chapter, verse: verse, ordinal: ordinal, path: path, fragment: anchor))
            }
        }
        guard !result.isEmpty else { throw BibleCopyError.missingBoundary }
        try book.verifySource()
        entries = result
    }
}

private final class AnchorScanner: NSObject, XMLParserDelegate {
    var anchors: [String] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard let id = attributes["id"], id.utf8.count == 9, id.first == "v", id.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return }
        anchors.append(id)
    }
}
