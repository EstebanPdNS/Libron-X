import Foundation

public enum BibleSearchRangeError: Error, LocalizedError, Sendable, Equatable {
    case invalidExpression, tooLarge, emptyReferenceList, missingReferenceList, notReferenceList, requiresVerseMode
    case invalidListEntry(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidExpression: "El rango contiene una referencia o un libro no reconocido."
        case .tooLarge: "El rango supera los límites de referencias permitidos."
        case .emptyReferenceList: "La lista de versículos seleccionada está vacía."
        case .missingReferenceList: "Selecciona una lista de versículos para delimitar la búsqueda."
        case .notReferenceList: "El documento seleccionado no es una lista de versículos."
        case .requiresVerseMode: "Los rangos bíblicos requieren búsqueda por versículo."
        case let .invalidListEntry(number): "La referencia \(number) de la lista no tiene un rango compatible."
        }
    }
}

/// A union of explicit source addresses, not a text window or a versification
/// converter. Construction compiles overlapping intervals once for binary lookup.
public struct BibleSearchRange: Sendable {
    public let description: String
    public let referenceCount: Int
    public let sourceDocumentID: UUID?
    public let sourceDocumentFingerprint: String?
    public var intervalCount: Int { intervals.values.reduce(0) { $0 + $1.count } }
    let intervals: [String: [BibleReferenceSpan]]
    private static let maximumEntries = 100_000
    private static let maximumUTF16 = 16_000_000

    public static func parse(_ input: String) throws -> Self {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BibleSearchRangeError.invalidExpression }
        guard trimmed.utf16.count <= maximumUTF16 else { throw BibleSearchRangeError.tooLarge }
        let citations = try parseExpression(trimmed)
        return try compile(citations, description: trimmed, referenceCount: citations.count)
    }
    public static func referenceList(_ document: StudyDocument) throws -> Self {
        try Task.checkCancellation(); try document.validate()
        guard document.kind == .verseList else { throw BibleSearchRangeError.notReferenceList }
        guard !document.verses.isEmpty else { throw BibleSearchRangeError.emptyReferenceList }
        guard document.verses.count <= maximumEntries else { throw BibleSearchRangeError.tooLarge }
        var citations: [BibleReferenceCitation] = [], length = 0
        for (index, entry) in document.verses.enumerated() {
            try Task.checkCancellation()
            length += entry.reference.utf16.count
            guard length <= maximumUTF16 else { throw BibleSearchRangeError.tooLarge }
            do { citations += try parseExpression(entry.reference) }
            catch is CancellationError { throw CancellationError() }
            catch BibleSearchRangeError.tooLarge { throw BibleSearchRangeError.tooLarge }
            catch { throw BibleSearchRangeError.invalidListEntry(index + 1) }
            guard citations.count <= maximumEntries else { throw BibleSearchRangeError.tooLarge }
        }
        struct Snapshot: Encodable { let id: UUID; let title: String; let references: [String] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Snapshot(id: document.id, title: document.title, references: document.verses.map(\.reference)))
        return try compile(citations, description: document.title, referenceCount: document.verses.count,
            documentID: document.id, fingerprint: LibrarySearchService.textFingerprint(String(decoding: data, as: UTF8.self)))
    }
    private static func parseExpression(_ input: String) throws -> [BibleReferenceCitation] {
        try Task.checkCancellation()
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw BibleSearchRangeError.invalidExpression }
        if input.utf16.count <= 4096, let direct = try? BibleReferenceQuery.parse(input) { return direct.citations }
        // First preserve the existing citation grammar, including inherited
        // chapters/verses. Fallback also allows whole books in a mixed union.
        let source = input as NSString
        var separators: [NSRange] = []
        for (offset, unit) in input.utf16.enumerated() {
            if offset.isMultiple(of: 4096) { try Task.checkCancellation() }
            if [10, 13, 44, 59].contains(unit) {
                guard separators.count < maximumEntries - 1 else { throw BibleSearchRangeError.tooLarge }
                separators.append(NSRange(location: offset, length: 1))
            }
        }
        var groups: [(text: String, citations: [BibleReferenceCitation])] = [], start = 0, previousSeparator = ";"
        for delimiter in separators + [NSRange(location: source.length, length: 0)] {
            try Task.checkCancellation()
            let segment = source.substring(with: NSRange(location: start, length: delimiter.location - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                if let parsed = try? BibleReferenceQuery.parse(segment) { groups.append((segment, parsed.citations)) }
                else if let last = groups.last, let parsed = try? BibleReferenceQuery.parse(last.text + previousSeparator + segment) {
                    groups[groups.count - 1] = (last.text + previousSeparator + segment, parsed.citations)
                } else { throw BibleSearchRangeError.invalidExpression }
            } else {
                let current = delimiter.length == 0 ? "" : source.substring(with: delimiter)
                guard previousSeparator == "\n" || previousSeparator == "\r" || current == "\n" || current == "\r" else {
                    throw BibleSearchRangeError.invalidExpression
                }
            }
            previousSeparator = delimiter.length == 0 ? ";" : source.substring(with: delimiter)
            start = NSMaxRange(delimiter)
        }
        guard !groups.isEmpty else { throw BibleSearchRangeError.invalidExpression }
        return groups.flatMap(\.citations)
    }
    private static func compile(_ citations: [BibleReferenceCitation], description: String, referenceCount: Int,
                                documentID: UUID? = nil, fingerprint: String? = nil) throws -> Self {
        guard !citations.isEmpty, citations.count <= maximumEntries else { throw BibleSearchRangeError.tooLarge }
        var grouped: [String: [BibleReferenceSpan]] = [:], count = 0
        for citation in citations {
            try Task.checkCancellation()
            count += citation.spans.count
            guard count <= maximumEntries else { throw BibleSearchRangeError.tooLarge }
            grouped[citation.edition ?? "", default: []] += citation.spans
        }
        for (edition, spans) in grouped {
            let ordered = spans.sorted { $0.lower == $1.lower ? $0.upper < $1.upper : $0.lower < $1.lower }
            var compact: [BibleReferenceSpan] = []
            for span in ordered {
                try Task.checkCancellation()
                if let last = compact.last, span.lower <= last.upper {
                    compact[compact.count - 1] = .init(lower: last.lower, upper: max(last.upper, span.upper))
                } else { compact.append(span) }
            }
            grouped[edition] = compact
        }
        return .init(description: description, referenceCount: referenceCount, sourceDocumentID: documentID,
                     sourceDocumentFingerprint: fingerprint, intervals: grouped)
    }
    func bind(to resource: LibraryResource) -> BibleSearchRangePredicate {
        let values = [resource.location.deletingPathExtension().lastPathComponent, resource.libron?.abbreviation].compactMap { $0 }
        let editions = Set(values.map { $0.lowercased() }.filter {
            !$0.isEmpty && $0.utf16.count <= 64 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
        })
        return .init(range: self, resourceEditions: editions)
    }
}

/// Called only after BibleVerseText validates the source verse directory.
struct BibleSearchRangePredicate: Sendable {
    let range: BibleSearchRange
    let resourceEditions: Set<String>
    func contains(_ verse: LibrarySearchBibleVerse) throws -> Bool {
        let pieces = verse.normalizedReference.split(whereSeparator: { $0 == " " || $0 == ":" })
        guard pieces.count == 3, BibleReferenceMentions.knownBooks.contains(String(pieces[0])),
              let chapter = Int(pieces[1]), let number = Int(pieces[2]) else { throw LibrarySearchError.invalidVerseDirectory }
        let address = BibleReferenceAddress(book: String(pieces[0]), chapter: chapter, verse: number)
        func member(_ edition: String) -> Bool {
            guard let spans = range.intervals[edition] else { return false }
            var low = 0, high = spans.count
            while low < high {
                let middle = low + (high - low) / 2
                if spans[middle].lower <= address { low = middle + 1 } else { high = middle }
            }
            return low > 0 && spans[low - 1].upper >= address
        }
        if member("") { return true }
        let source = verse.reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if source.hasPrefix("bible+"), let scheme = source.split(separator: ".").first {
            return member(String(scheme.dropFirst(6)))
        }
        return resourceEditions.contains(where: member)
    }
}
