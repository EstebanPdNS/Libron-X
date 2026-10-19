import AppKit
import Foundation
import LibronixCore

/// Explicit source addresses only. A gap never inherits the previous note.
struct StandaloneCommentaryEntry: Codable, Sendable {
    var start: String
    var end: String
    var ordinal: Int
    var offset: Int
    let passage: BibleCopyPassage?
    enum CodingKeys: String, CodingKey { case start, end, ordinal, offset }
    init(start: String, end: String, ordinal: Int, offset: Int) {
        self.start = start; self.end = end; self.ordinal = ordinal; self.offset = offset
        passage = try? BibleCopyPassage.parse(start + "-" + end)
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(start: try values.decode(String.self, forKey: .start), end: try values.decode(String.self, forKey: .end),
                  ordinal: try values.decode(Int.self, forKey: .ordinal), offset: try values.decode(Int.self, forKey: .offset))
    }
}

extension LibronNativeReader {
    func standaloneIndex(_ resource: LibraryResource) throws -> [StandaloneCommentaryEntry] {
        guard let url = Self.location(resource), let header = try header(resource) else { throw RebuildError.unsupportedFormat }
        if let saved = standaloneIndexes[url] { return saved }
        let db = try LibronNativeDatabase(url)
        var result: [StandaloneCommentaryEntry] = []
        if let data = try db.get("commentary-index") {
            result = try JSONDecoder().decode([StandaloneCommentaryEntry].self, from: data)
            guard result.count <= 300_000 else { throw LibronError.invalid("Commentary index exceeds limit") }
            if let invalid = result.first(where: { !(0..<header.sectionCount).contains($0.ordinal) || $0.offset < 0 || $0.passage == nil }) {
                throw LibronError.invalid("Invalid commentary index: " + invalid.start)
            }
        } else {
            for entry in header.entries {
                if let passage = try? BibleCopyPassage.parse(entry.title) {
                    result.append(.init(start: passage.start.key, end: passage.end.key, ordinal: entry.ordinal, offset: 0))
                }
            }
            for point in try db.referenceEntries() {
                result.append(.init(start: point.reference, end: point.reference, ordinal: point.ordinal, offset: point.offset))
            }
        }
        if standaloneIndexes.count >= 16 { standaloneIndexes.removeAll() }
        standaloneIndexes[url] = result
        return result
    }
    func readStandaloneCommentary(_ resource: LibraryResource, _ request: ReaderDestination) async throws -> ReaderPage {
        guard let query = request.reference.flatMap(LegacyPassageQuery.sourceReference),
              let url = Self.location(resource), let header = try header(resource) else { throw RebuildError.referenceNotFound }
        let chapter = "\(query.sourceBookKey) \(query.chapter):1"
        var result: ReaderPage
        if let saved = commentaryChapters[url]?[chapter] { result = saved }
        else {
            let indexed = try standaloneIndex(resource)
            let entries = indexed.compactMap { entry -> (StandaloneCommentaryEntry, BibleCopyPassage)? in
                guard let range = entry.passage, range.start.bookKey == query.sourceBookKey,
                      range.start.chapter <= query.chapter, range.end.chapter >= query.chapter else { return nil }
                return (entry, range)
            }.sorted { lhs, rhs in
                let a = lhs.1.start, b = rhs.1.start
                return (a.chapter, a.verse, lhs.0.ordinal) < (b.chapter, b.verse, rhs.0.ordinal)
            }
            let combined = NSMutableAttributedString(string: "")
            var offsets: [Int: Int] = [:], lengths: [Int: Int] = [:], links: [LegacyInlineLink] = [], graphics: [LegacyGraphicAsset] = []
            for (entry, _) in entries where offsets[entry.ordinal] == nil {
                try Task.checkCancellation()
                let note = try await read(resource, .init(ordinal: entry.ordinal))
                let heading = entry.start == entry.end ? entry.start : "\(entry.start)–\(entry.end)"
                combined.append(NSAttributedString(string: heading + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
                let offset = combined.length; offsets[entry.ordinal] = offset; lengths[entry.ordinal] = note.text.utf16.count
                let value = note.content?.richTextRTF.flatMap {
                    try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                }
                combined.append(value?.string == note.text ? value! : NSAttributedString(string: note.text))
                combined.append(NSAttributedString(string: "\n\n"))
                links += note.inlineLinks.map { link in
                    var shifted = LegacyInlineLink(range: .init(location: link.range.location + offset, length: link.range.length),
                        label: link.label, sourceName: link.sourceName, target: link.target)
                    shifted.role = link.role; return shifted
                }
                graphics += note.graphics.map { $0.offsettingCharacters(by: offset) }
            }
            var locations: [String: Int] = [:], spans: [String: Int] = [:]
            for (entry, range) in entries {
                let first = range.start.chapter == query.chapter ? range.start.verse : 1
                let last = range.end.chapter == query.chapter ? range.end.verse : 1000
                guard first > 0, last >= first, last <= 1000, let offset = offsets[entry.ordinal], entry.offset <= lengths[entry.ordinal, default: 0] else { continue }
                let span = (range.end.chapter - range.start.chapter) * 1001 + range.end.verse - range.start.verse
                for verse in first...last {
                    let key = "\(query.sourceBookKey) \(query.chapter):\(verse)"
                    if spans[key].map({ span < $0 }) ?? true {
                        locations[key] = offset + entry.offset; spans[key] = span
                    }
                }
            }
            let text = combined.string
            let rtf = try combined.data(from: .init(location: 0, length: combined.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            result = .init(destination: .init(ordinal: entries.first?.0.ordinal ?? 0, commentaryChapter: chapter), text: text,
                sectionCount: header.sectionCount, entries: header.entries, content: .imported(text: text, ordinal: entries.first?.0.ordinal ?? 0, anchors: [], rtf: rtf),
                graphics: graphics, inlineLinks: links, commentaryLocations: locations)
            if commentaryChapters.values.reduce(0, { $0 + $1.count }) >= 8 { commentaryChapters.removeAll() }
            commentaryChapters[url, default: [:]][chapter] = result
        }
        result.destination.reference = query.displayReference
        result.selection = .init(location: result.commentaryLocations[query.normalizedKey] ?? 0, length: 0)
        return result
    }
}
