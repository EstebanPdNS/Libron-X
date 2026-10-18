import Foundation

public enum BibleReferenceSearchError: Error, LocalizedError, Equatable, Sendable {
    case invalidQuery, invalidRange, sourceLimit, mentionLimit
    public var errorDescription: String? {
        switch self {
        case .invalidQuery: "La consulta no es una referencia bíblica reconocida."
        case .invalidRange: "La referencia no conserva un rango válido en el texto fuente."
        case .sourceLimit: "El texto supera el límite de extracción de referencias."
        case .mentionLimit: "Se alcanzó el límite de referencias explícitas del artículo."
        }
    }
}

/// Canonical book spelling only. Comparing these keys never converts the
/// numbering of a passage from one edition's versification into another.
public struct BibleReferenceAddress: Codable, Hashable, Sendable, Comparable {
    public let book: String
    public let chapter: Int
    public let verse: Int
    private static let order = Dictionary(uniqueKeysWithValues: LegacyPassageQuery.referenceBookOrder.enumerated().map { ($0.element,$0.offset) })
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let a = order[lhs.book] ?? Int.max, b = order[rhs.book] ?? Int.max
        if a != b { return a < b }
        if lhs.book != rhs.book { return lhs.book < rhs.book }
        return (lhs.chapter,lhs.verse) < (rhs.chapter,rhs.verse)
    }
}
public struct BibleReferenceSpan: Codable, Hashable, Sendable {
    public let lower: BibleReferenceAddress
    public let upper: BibleReferenceAddress
    public func intersects(_ other: Self) -> Bool { lower <= other.upper && other.lower <= upper }
}
public struct BibleReferenceCitation: Codable, Hashable, Sendable {
    public let spans: [BibleReferenceSpan]
    /// Lowercase explicit source identifier. nil means unspecified, never an
    /// inferred edition based on the containing book or interface language.
    public let edition: String?
    public func accepts(_ mention: Self) -> Bool {
        (edition == nil || edition == mention.edition) && spans.contains { a in mention.spans.contains { a.intersects($0) } }
    }
}
public struct BibleReferenceMention: Codable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable { case visibleText, explicitLink }
    public let citation: BibleReferenceCitation
    public let range: SearchTextRange
    public let label: String
    public let origin: Origin
}
public struct BibleReferenceSourceLink: Codable, Hashable, Sendable {
    public let range: SearchTextRange
    public let target: String
    public init(range: SearchTextRange, target: String) { self.range = range; self.target = target }
}
public struct BibleReferenceQuery: Sendable {
    public let original: String
    public let citations: [BibleReferenceCitation]
    public static func parse(_ input: String) throws -> Self {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 4096 else { throw BibleReferenceSearchError.invalidQuery }
        let mentions = try BibleReferenceMentions.extract(text)
        if !mentions.isEmpty {
            let source = text as NSString
            var end = 0
            for mention in mentions {
                let gap = source.substring(with: NSRange(location:end,length:mention.range.location-end))
                guard gap.allSatisfy({ $0.isWhitespace || ",;".contains($0) }) else { throw BibleReferenceSearchError.invalidQuery }
                end = mention.range.upperBound
            }
            guard source.substring(from:end).allSatisfy({ $0.isWhitespace || $0 == "." }) else { throw BibleReferenceSearchError.invalidQuery }
            return .init(original:input,citations:mentions.map(\.citation))
        }
        // A whole-book query matches explicit mentions within that known book.
        let expanded = text + " 1:1"
        if let book = try BibleReferenceMentions.extract(expanded).first,
           book.range.location == 0, book.range.upperBound == expanded.utf16.count,
           book.citation.spans.count == 1, book.citation.edition == nil {
            let key = book.citation.spans[0].lower.book
            return .init(original:input,citations:[.init(spans:[.init(lower:.init(book:key,chapter:0,verse:0),
                upper:.init(book:key,chapter:65535,verse:65535))],edition:nil)])
        }
        throw BibleReferenceSearchError.invalidQuery
    }
    public func matches(_ mention: BibleReferenceMention) -> Bool { citations.contains { $0.accepts(mention.citation) } }
}

/// Extracts explicit, bounded reference syntax without translating book text.
/// UTF-16 offsets always belong to the unchanged reader string.
public enum BibleReferenceMentions {
    static let knownBooks = Set(LegacyPassageQuery.referenceBookOrder)
    private static let orderedRangeBooks = LegacyPassageQuery.referenceRangeBooks
    private static let spaces = #"[ \t\u00a0]*"#
    private static let bookPattern: String = {
        func spelling(_ name: String) -> String {
            var value = ""
            for (index,char) in name.enumerated() {
                if char.isWhitespace { value += #"[ \t\u00a0]+"#; continue }
                if index == 0, let n = Int(String(char)), (1...3).contains(n) {
                    let roman = ["I","II","III"][n-1]
                    value += "(?:" + String(n) + #"(?:\.[ºª°]?|[ºª°])?[ \t\u00a0]*|"# + roman + #"\.?[ \t\u00a0]+)"#
                    continue
                }
                let raw = String(char), decomposed = raw.decomposedStringWithCanonicalMapping
                let quoted = NSRegularExpression.escapedPattern(for:raw)
                value += raw.utf8.elementsEqual(decomposed.utf8) ? quoted : "(?:" + quoted + "|" + NSRegularExpression.escapedPattern(for:decomposed) + ")"
            }
            return value
        }
        return Array(Set(LegacyPassageQuery.referenceBookNames)).sorted { $0.utf16.count == $1.utf16.count ? $0 < $1 : $0.utf16.count > $1.utf16.count }
            .map(spelling).joined(separator:"|")
    }()
    private static let initial = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{M}\p{N}_])("# + bookPattern + #")\.?"# + spaces +
        #"([0-9]{1,5})(?:"# + spaces + #"[:.,：．，/]"# + spaces + #"([0-9]{1,5}))?(?![\p{L}\p{M}\p{N}_:：/])"#, options:[.caseInsensitive])
    private static let serialized = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{N}_])bible(?:\+[A-Za-z0-9_-]{1,64})?\.[0-9]{1,3}\.[0-9]{1,5}\.[0-9]{1,5}(?![\p{L}\p{N}_.])"#, options:[.caseInsensitive])
    private static let scan = try! NSRegularExpression(pattern:"(?:" + initial.pattern + ")|(" + serialized.pattern + ")",options:[.caseInsensitive])
    private static let number = try! NSRegularExpression(pattern: spaces + #"([0-9]{1,5})(?:"# + spaces + #"[:：]"# + spaces + #"([0-9]{1,5}))?(?![\p{L}\p{M}\p{N}_:：/])"#)
    private static let edition = try! NSRegularExpression(pattern: spaces + #"\(([A-Za-z0-9_][A-Za-z0-9_.-]{0,63})\)"#)
    private static let separator = try! NSRegularExpression(pattern:spaces + #"([,;])"# + spaces)
    private static let dash = try! NSRegularExpression(pattern:spaces + #"[-–—]"# + spaces)
    private struct Start {
        var span: BibleReferenceSpan
        var end: Int
        var chapterOnly: Bool
        var edition: String?
        var editionExplicit = false
    }
    private struct Part { var span: BibleReferenceSpan; var range: NSRange; var edition: String? }
    private struct Parsed { var parts: [Part]?; var end: Int }
    private static func anchored(_ regex: NSRegularExpression, _ text: NSString, at offset: Int) -> NSTextCheckingResult? {
        guard offset < text.length else { return nil }
        return regex.firstMatch(in:text as String,options:[.anchored],range:NSRange(location:offset,length:text.length-offset))
    }
    private static func start(_ match: NSTextCheckingResult, text: NSString, wire: Bool) -> Start? {
        let raw = text.substring(with:match.range)
        if wire {
            guard let q = LegacyPassageQuery.sourceReference(raw), knownBooks.contains(q.sourceBookKey),
                  !LegacyPassageQuery.referenceSingleChapterBooks.contains(q.sourceBookKey) || q.chapter == 1 else { return nil }
            let address = BibleReferenceAddress(book:q.sourceBookKey,chapter:q.chapter,verse:q.verse)
            let scheme = raw.split(separator:".")[0].split(separator:"+",omittingEmptySubsequences:false)
            return .init(span:.init(lower:address,upper:address),end:NSMaxRange(match.range),chapterOnly:false,
                         edition:scheme.count == 2 ? String(scheme[1]).lowercased() : nil,editionExplicit:scheme.count == 2)
        }
        let book = text.substring(with:match.range(at:1)), chapter = text.substring(with:match.range(at:2))
        let whole = match.range(at:3).location == NSNotFound
        let verse = whole ? "1" : text.substring(with:match.range(at:3))
        var spelling = book.precomposedStringWithCanonicalMapping.replacingOccurrences(of:#"^([1-3])[.ºª°]+\s*"#,with:"$1 ",options:.regularExpression)
        for (roman,n) in [("iii",3),("ii",2),("i",1)] {
            if let prefix = spelling.range(of:"(?i)^" + roman + #"\.?[ \t\u00a0]+"#,options:.regularExpression) {
                spelling = String(n) + String(spelling[prefix.upperBound...]);break
            }
        }
        guard let q = LegacyPassageQuery.parse(spelling + " " + chapter + ":" + verse), knownBooks.contains(q.sourceBookKey) else { return nil }
        let oneChapter = LegacyPassageQuery.referenceSingleChapterBooks.contains(q.sourceBookKey)
        guard !oneChapter || whole || q.chapter == 1 else { return nil }
        let chapterOnly = whole && !oneChapter
        let resolvedChapter = whole && oneChapter ? 1 : q.chapter
        let resolvedVerse = whole && oneChapter ? q.chapter : q.verse
        return .init(span:.init(lower:.init(book:q.sourceBookKey,chapter:resolvedChapter,verse:chapterOnly ? 0 : resolvedVerse),
                               upper:.init(book:q.sourceBookKey,chapter:resolvedChapter,verse:chapterOnly ? 65535 : resolvedVerse)),
                     end:NSMaxRange(match.range),chapterOnly:chapterOnly,edition:nil)
    }
    private static func numeric(_ text: NSString, at offset: Int, context: Start, semicolon: Bool = false) -> Start? {
        guard let match = anchored(number,text,at:offset), let a = Int(text.substring(with:match.range(at:1))), (1...65535).contains(a) else { return nil }
        let explicitChapter = match.range(at:2).location != NSNotFound
        let oneChapter = LegacyPassageQuery.referenceSingleChapterBooks.contains(context.span.upper.book)
        let whole = !explicitChapter && (context.chapterOnly || semicolon) && !oneChapter
        let chapter = explicitChapter || whole ? a : context.span.upper.chapter
        let b = explicitChapter ? Int(text.substring(with:match.range(at:2))) : Optional(whole ? 0 : a)
        guard let b, (0...65535).contains(b), !explicitChapter || b > 0, !oneChapter || chapter == 1 else { return nil }
        return .init(span:.init(lower:.init(book:context.span.upper.book,chapter:chapter,verse:b),
                               upper:.init(book:context.span.upper.book,chapter:chapter,verse:whole ? 65535 : b)),
                     end:NSMaxRange(match.range),chapterOnly:whole,edition:context.edition)
    }
    private static func endpoint(_ text: NSString, at offset: Int, context: Start) -> Start? {
        if let m = anchored(serialized,text,at:offset) { return start(m,text:text,wire:true) }
        if let m = anchored(initial,text,at:offset) { return start(m,text:text,wire:false) }
        return numeric(text,at:offset,context:context)
    }
    private static func citation(_ first: Start, text: NSString, startOffset: Int) throws -> Parsed {
        var current = first, cursor = first.end, inheritedEdition = first.edition
        var segmentStart = startOffset, parts: [Part] = []
        while true {
            try Task.checkCancellation()
            var span = current.span, partEdition = current.edition ?? inheritedEdition
            var explicitOnSpan = current.editionExplicit
            if let hyphen = anchored(dash,text,at:cursor) {
                let next = NSMaxRange(hyphen.range)
                guard let end = endpoint(text,at:next,context:current) else { return .init(parts:nil,end:next) }
                cursor = end.end
                guard span.lower.book == end.span.upper.book || (orderedRangeBooks.contains(span.lower.book) && orderedRangeBooks.contains(end.span.upper.book)),
                      span.lower <= end.span.upper else { return .init(parts:nil,end:cursor) }
                if end.editionExplicit {
                    guard !explicitOnSpan || partEdition == end.edition else { return .init(parts:nil,end:cursor) }
                    partEdition = end.edition;explicitOnSpan = true
                }
                span = .init(lower:span.lower,upper:end.span.upper);current = end
            }
            if let suffix = anchored(edition,text,at:cursor) {
                let value = text.substring(with:suffix.range(at:1)).lowercased()
                guard !explicitOnSpan || partEdition == value else { return .init(parts:nil,end:NSMaxRange(suffix.range)) }
                // A first trailing edition qualifies the preceding unqualified
                // list. A later edition starts a new group instead of erasing
                // already explicit references from another edition.
                if inheritedEdition == nil { for i in parts.indices where parts[i].edition == nil { parts[i].edition = value } }
                partEdition = value;cursor = NSMaxRange(suffix.range)
            }
            parts.append(.init(span:span,range:NSRange(location:segmentStart,length:cursor-segmentStart),edition:partEdition))
            guard parts.count <= 256 else { throw BibleReferenceSearchError.mentionLimit }
            inheritedEdition = partEdition;current.edition = partEdition
            guard let sep = anchored(separator,text,at:cursor),
                  let following = numeric(text,at:NSMaxRange(sep.range),context:current,semicolon:text.substring(with:sep.range(at:1)) == ";") else { break }
            segmentStart = NSMaxRange(sep.range);cursor = following.end;current = following
        }
        return .init(parts:parts,end:cursor)
    }
    public static func extract(_ source: String, within requested: SearchTextRange? = nil,
                               links: [BibleReferenceSourceLink] = []) throws -> [BibleReferenceMention] {
        try Task.checkCancellation()
        guard links.count <= 100_000 else { throw BibleReferenceSearchError.mentionLimit }
        let full = source as NSString
        guard full.length <= 16_000_000 else { throw BibleReferenceSearchError.sourceLimit }
        let scope = requested ?? .init(location:0,length:full.length)
        try validate(scope,in:source)
        let text = full.substring(with:scope.nsRange) as NSString
        var result: [BibleReferenceMention] = [], linkRanges: [NSRange] = []
        var linkIdentities: [SearchTextRange: BibleReferenceCitation] = [:]
        for link in links {
            try Task.checkCancellation();try validate(link.range,in:source)
            guard link.range.length > 0 else { throw BibleReferenceSearchError.invalidRange }
            let raw: String
            if link.target.hasPrefix("=r") {
                guard let legacy = LegacyBibleLinkReference.parse(link.target) else { continue }
                let a = legacy.passage.start, b = legacy.passage.end
                raw = "\(a.bookKey) \(a.chapter):\(a.verse)" + (a == b ? "" : "-\(b.bookKey) \(b.chapter):\(b.verse)") + (legacy.edition.map { "(" + $0 + ")" } ?? "")
            } else { raw = link.target }
            guard let query = try? BibleReferenceQuery.parse(raw), query.citations.count == 1 else { continue }
            let visible = NSIntersectionRange(scope.nsRange,link.range.nsRange)
            guard visible.length > 0 else { continue }
            // A link crossing a logical article boundary belongs to its start
            // article. Later articles suppress its label without duplicating it.
            linkRanges.append(visible)
            guard link.range.location >= scope.location, link.range.location < scope.upperBound else { continue }
            let owned = SearchTextRange(location:visible.location,length:visible.length)
            if let previous = linkIdentities[owned] {
                guard previous == query.citations[0] else { throw BibleReferenceSearchError.invalidRange }
                continue
            }
            linkIdentities[owned] = query.citations[0]
            result.append(.init(citation:query.citations[0],range:owned,label:full.substring(with:visible),origin:.explicitLink))
        }
        let sortedLinks = linkRanges.sorted { $0.location < $1.location }
        var covered: [NSRange] = []
        for range in sortedLinks {
            if let last = covered.last, range.location <= NSMaxRange(last) {
                covered[covered.count-1] = NSRange(location:last.location,length:max(NSMaxRange(last),NSMaxRange(range))-last.location)
            } else { covered.append(range) }
        }
        func overlapsLink(_ range: NSRange) -> Bool {
            var low = 0, high = covered.count
            while low < high {
                let mid = low+(high-low)/2
                if NSMaxRange(covered[mid]) <= range.location { low = mid+1 } else { high = mid }
            }
            return low < covered.count && covered[low].location < NSMaxRange(range)
        }
        var cursor = 0
        while cursor < text.length {
            try Task.checkCancellation()
            let range = NSRange(location:cursor,length:text.length-cursor)
            guard let match = scan.firstMatch(in:text as String,range:range) else { break }
            let wire = match.range(at:4).location != NSNotFound
            cursor = NSMaxRange(match.range)
            guard let first = start(match,text:text,wire:wire) else { continue }
            let parsed = try citation(first,text:text,startOffset:match.range.location);cursor = max(cursor,parsed.end)
            guard let parsedParts = parsed.parts else { continue }
            let parts = parsedParts.map { part in
                Part(span:part.span,range:NSRange(location:part.range.location+scope.location,length:part.range.length),edition:part.edition)
            }.filter { !overlapsLink($0.range) }
            var groups: [[Part]] = []
            for part in parts {
                if let last = groups.last, last[0].edition == part.edition { groups[groups.count-1].append(part) }
                else { groups.append([part]) }
            }
            for group in groups {
                guard let firstPart = group.first, let lastPart = group.last else { continue }
                let hitRange = NSRange(location:firstPart.range.location,length:NSMaxRange(lastPart.range)-firstPart.range.location)
                result.append(.init(citation:.init(spans:group.map(\.span),edition:firstPart.edition),range:.init(location:hitRange.location,length:hitRange.length),
                                    label:full.substring(with:hitRange),origin:.visibleText))
            }
            guard result.count <= 100_000 else { throw BibleReferenceSearchError.mentionLimit }
        }
        return result.sorted {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length < $1.range.length }
            return $0.origin.rawValue < $1.origin.rawValue
        }
    }
    private static func validate(_ range: SearchTextRange, in text: String) throws {
        let length = text.utf16.count
        guard range.location >= 0, range.length >= 0, range.location <= length, range.length <= length-range.location,
              Range(range.nsRange,in:text) != nil else { throw BibleReferenceSearchError.invalidRange }
        let source = text as NSString
        guard (range.location == length || source.rangeOfComposedCharacterSequence(at:range.location).location == range.location),
              (range.upperBound == length || source.rangeOfComposedCharacterSequence(at:range.upperBound).location == range.upperBound) else { throw BibleReferenceSearchError.invalidRange }
    }
}
