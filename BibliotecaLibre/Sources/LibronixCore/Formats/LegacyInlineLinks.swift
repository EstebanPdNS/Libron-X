import Foundation

/// A measured legacy =r destination. The complete address comes from the
/// attribute, including when the visible label is only a verse number.
public struct LegacyBibleLinkReference: Codable, Sendable, Equatable {
    public let passage: BibleCopyPassage
    public let edition: String?
    public static func parse(_ attribute: String) -> Self? {
        guard attribute.hasPrefix("=r"), attribute.utf16.count <= 512 else { return nil }
        var body = String(attribute.dropFirst(2)), edition: String?
        if let open = body.lastIndex(of: "(") {
            guard body.last == ")" else { return nil }
            let name = String(body[body.index(after: open)..<body.index(before: body.endIndex)])
            guard !name.isEmpty, name.count <= 64,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }) else { return nil }
            edition = name; body = String(body[..<open])
        }
        guard !body.contains("("), !body.contains(")") else { return nil }
        // The source dialect omits the chapter for one-chapter books.
        if let one = LegacyPassageQuery.sourceReference(body) { body = one.displayReference }
        guard let passage = try? BibleCopyPassage.parse(body), !passage.wholeChapter else { return nil }
        return .init(passage: passage, edition: edition)
    }
}

public enum LegacyInlineLinkTarget: Codable, Sendable, Equatable {
    case article(Int)
    case bible(LegacyBibleLinkReference)
}

/// An unchanged source-text span linked to an explicit, checked destination.
/// The destination is a physical article in the same resource, never a command,
/// URL or an offset copied from another edition. Bible addresses require their
/// explicit serialized =r destination; label text is never inferred.
public struct LegacyInlineLink: Codable, Sendable, Equatable {
    public let range: NSRange
    public let label: String
    public let sourceName: String
    public let target: LegacyInlineLinkTarget
    public var sectionOrdinal: Int? { if case let .article(ordinal) = target { ordinal } else { nil } }
    public init(range: NSRange, label: String, sourceName: String, sectionOrdinal: Int) {
        self.init(range: range, label: label, sourceName: sourceName, target: .article(sectionOrdinal))
    }
    public init(range: NSRange, label: String, sourceName: String, target: LegacyInlineLinkTarget) {
        self.range = range; self.label = label; self.sourceName = sourceName; self.target = target
    }
}

public struct LegacyInlineLinkResolution: Sendable, Equatable {
    public let links: [LegacyInlineLink]
    public let unresolvedAttributedRuns: Int
}

public struct LegacyNamedPositionLookup: Sendable {
    fileprivate let positions: [String:[LegacyNamedPosition]]
    public init(_ positions: [LegacyNamedPosition]) { self.positions = Dictionary(grouping:positions,by:\.label) }
}

public enum LegacyInlineLinks {
    public static func resolve(content: LegacySectionContent, namedPositions: [LegacyNamedPosition]) -> LegacyInlineLinkResolution {
        resolve(content:content,lookup:LegacyNamedPositionLookup(namedPositions))
    }
    public static func resolve(content: LegacySectionContent, lookup: LegacyNamedPositionLookup) -> LegacyInlineLinkResolution {
        let named = lookup.positions
        let source = content.plainText as NSString
        var links: [LegacyInlineLink] = [], unresolved = 0
        for run in content.runs {
            let candidates = [run.attribute].compactMap { $0 } +
                (run.extendedAttributes?.strings.map { LegacyResourceReader.decodeCP1252($0) } ?? [])
            guard !candidates.isEmpty else { continue }
            let targets = candidates.flatMap { named[$0] ?? [] }
            // Additional fields and ambiguous names are not interpreted as
            // commands. A unique literal source-index match is required.
            let ordinals = Set(targets.map(\.articleID))
            var destinations: [LegacyInlineLinkTarget] = ordinals.map { .article(Int($0)) }
            for candidate in candidates {
                if let reference = LegacyBibleLinkReference.parse(candidate),
                   !destinations.contains(.bible(reference)) { destinations.append(.bible(reference)) }
            }
            guard run.characterOffset >= 0, run.characterOffset <= source.length,
                  !run.hasLeadingSoftBreak || run.characterOffset < source.length else { unresolved += 1; continue }
            let span = NSRange(location: run.storedTextCharacterOffset, length: run.text.utf16.count)
            guard destinations.count == 1, let target = destinations.first,
                  span.length > 0, span.location <= source.length, span.length <= source.length - span.location,
                  Range(span, in: content.plainText) != nil, source.substring(with: span) == run.text else {
                unresolved += 1; continue
            }
            links.append(.init(range: span, label: run.text, sourceName: candidates.first ?? "", target: target))
        }
        return .init(links: links, unresolvedAttributedRuns: unresolved)
    }
}
