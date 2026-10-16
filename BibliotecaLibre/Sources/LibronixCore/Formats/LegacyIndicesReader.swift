import Foundation

public struct LegacyTitleSegment: Sendable, Codable, Equatable {
    /// Selector codes include locale-like and font/script-like values. Preserve
    /// the code without interpreting every value as a Windows language ID.
    public let selectorCode: UInt16?
    public let text: String
}

public struct LegacyArticleIndexEntry: Sendable, Codable, Equatable {
    public let directoryRow: Int
    public let articleID: UInt32
    public let relativeTartOffset: UInt32
    public let titleOffset: UInt32?
    public let flags: UInt32
    public let indexWithinLevel: UInt32
    public let level: UInt8
    public let titleSegments: [LegacyTitleSegment]
    public var title: String? { titleSegments.isEmpty ? nil : titleSegments.map(\.text).joined() }
}

/// IDs retain the resource's own encoding. No versification is inferred.
public struct LegacyReferencePosition: Sendable, Codable, Equatable {
    public let referenceID: UInt16
    public let startArticleID: UInt32
    public let startCharacterOffset: UInt32
    public let endArticleID: UInt32
    public let endCharacterOffset: UInt32
}

public struct LegacyArticleReferenceRange: Sendable, Codable, Equatable {
    public let articleID: UInt32
    public let firstReferenceID: UInt16
    public let lastReferenceID: UInt16
}

public struct LegacyIndicesInspection: Sendable, Codable, Equatable {
    public let sections: LegacySectionIndex
    public let articles: [LegacyArticleIndexEntry]
    public let referencePositions: [LegacyReferencePosition]
    public let articleReferenceRanges: [LegacyArticleReferenceRange]
    public let namedPositions: [LegacyNamedPosition]
    public let warnings: [String]
}

/// A parsed label actually present in a resource, not a canonical Bible schema.
public struct LegacyObservedBibleReference: Sendable, Codable, Equatable {
    public let original: String
    public let bookCode: String
    public let chapter: Int
    public let verse: Int

    public var normalizedKey: String {
        bookCode.lowercased().filter { !$0.isWhitespace && $0 != "." } + " \(chapter):\(verse)"
    }

    public static func parse(_ value: String) -> LegacyObservedBibleReference? {
        guard value.utf16.count <= 512 else { return nil }
        let pattern = #"^\s*((?:[1-3]\s*|[Ii]{1,3}\s+)?[\p{L}.]+(?:\s+[\p{L}.]+)*)\s*(\d+):(\d+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let bookRange = Range(match.range(at: 1), in: value),
              let chapterRange = Range(match.range(at: 2), in: value),
              let verseRange = Range(match.range(at: 3), in: value),
              let chapter = Int(value[chapterRange]), let verse = Int(value[verseRange]),
              chapter > 0, chapter <= 65535, verse > 0, verse <= 65535 else { return nil }
        return LegacyObservedBibleReference(original: value, bookCode: String(value[bookRange]), chapter: chapter, verse: verse)
    }
}

public struct LegacyReferenceMatch: Sendable, Codable, Equatable {
    public let observedReference: String
    public let articleID: UInt32
    public let sectionOrdinal: Int
    public let startCharacterOffset: Int
    public let endCharacterOffsetExclusive: Int
    public let referencePosition: LegacyReferencePosition?
    public let text: String
    public let warnings: [String]
}

public struct LegacyReferenceResolution: Sendable, Codable, Equatable {
    public let query: String
    public let match: LegacyReferenceMatch?
    public let candidatesExamined: Int
    public let totalCandidates: Int
    public let exhaustedCandidates: Bool
    public let diagnostics: [String]
}

public enum LegacyIndicesError: Error, Sendable, Equatable, LocalizedError {
    case mismatchedPair
    case missingArticleIndex
    case invalidTable(String)
    case tableLimitExceeded
    case articlePointerMismatch(UInt32)
    case invalidObservedReference
    case invalidReferenceRange
    case crossArticleReferenceUnsupported
    case sourceChanged
    case directoryRowNotFound(Int)

    public var errorDescription: String? {
        switch self {
        case .mismatchedPair: "Los identificadores de LSF y LIX no coinciden."
        case .missingArticleIndex: "El índice LIX no contiene AIDX."
        case let .invalidTable(tag): "La tabla \(tag) no coincide con el formato observado."
        case .tableLimitExceeded: "El índice solicitado supera el límite seguro."
        case let .articlePointerMismatch(id): "El artículo \(id) apunta a una sección que no coincide con el contenedor."
        case .invalidObservedReference: "Escribe una referencia como Génesis 4:1, Gen 4.1 o Gn 4,1. Los intervalos todavía no se interpretan."
        case .invalidReferenceRange: "La posición de referencia no encaja en el texto decodificado."
        case .crossArticleReferenceUnsupported: "La referencia abarca varios artículos; su intervalo todavía no se interpreta."
        case .sourceChanged: "El archivo cambió durante la lectura; vuelve a abrir el recurso."
        case let .directoryRowNotFound(row): "La fila de contenido \(row) no existe."
        }
    }
}

public enum LegacyIndicesReader {
    public static func inspect(lsfURL: URL, lixURL: URL, allowUnavailableIndexBlocks: Bool = false) throws -> LegacyIndicesInspection {
        let pair = try LegacyResourceReader.inspect(lsfURL: lsfURL, lixURL: lixURL, allowUnavailableIndexBlocks: allowUnavailableIndexBlocks)
        guard pair.identifiersMatch == true, let indexMetadata = pair.lix else { throw LegacyIndicesError.mismatchedPair }
        let sections = try LegacyContentReader.inspectSections(lsfURL: lsfURL)
        let stream = try FileHandle(forReadingFrom: lixURL)
        defer { try? stream.close() }
        let fileSize = try stream.seekToEnd()
        let blocks = indexMetadata.blocks
        func blockData(_ block: LegacyBlock) throws -> Data {
            guard block.length <= 16 * 1024 * 1024, block.offset >= 8,
                  block.offset <= fileSize, block.length <= fileSize - block.offset else { throw LegacyIndicesError.tableLimitExceeded }
            try stream.seek(toOffset: block.offset - 8)
            guard let header = try stream.read(upToCount: 8), header.count == 8,
                  String(decoding: header.prefix(4), as: UTF8.self) == block.tag,
                  UInt64(u32(header, 4)) == block.length else { throw LegacyIndicesError.invalidTable(block.tag) }
            var output = Data()
            while output.count < Int(block.length) {
                guard let bytes = try stream.read(upToCount: Int(block.length) - output.count), !bytes.isEmpty else {
                    throw LegacyIndicesError.invalidTable(block.tag)
                }
                output.append(bytes)
            }
            return output
        }
        func child(_ tag: String, within parent: LegacyBlock) -> LegacyBlock? {
            blocks.first { $0.tag == tag && $0.offset >= parent.offset && $0.offset + $0.length <= parent.offset + parent.length }
        }
        guard let articleIndex = blocks.first(where: { $0.tag == "AIDX" }),
              let articleInfo = child("info", within: articleIndex),
              let articleHits = child("hlst", within: articleIndex),
              let articleKeys = child("klst", within: articleIndex) else { throw LegacyIndicesError.missingArticleIndex }
        let info = try blockData(articleInfo)
        guard info.count == 12, u16(info, 0) == 0 else { throw LegacyIndicesError.invalidTable("AIDX/info") }
        let recordCount = Int(u32(info, 2))
        guard recordCount <= 500_000, UInt64(recordCount) * 21 == articleHits.length,
              Int(u32(info, 6)) == sections.sections.count else { throw LegacyIndicesError.invalidTable("AIDX/hlst") }
        let hits = try blockData(articleHits)
        let keys = try blockData(articleKeys)
        var warnings: [String] = []
        var articles: [LegacyArticleIndexEntry] = []
        var titleCache: [UInt32: [LegacyTitleSegment]] = [:]
        articles.reserveCapacity(recordCount)
        for row in 0..<recordCount {
            if row.isMultiple(of: 256) { try Task.checkCancellation() }
            let at = row * 21
            let id = u32(hits, at)
            let relative = u32(hits, at + 4)
            guard Int(id) < sections.sections.count,
                  sections.sections[Int(id)].headerOffset - sections.tartOffset == UInt64(relative) else {
                throw LegacyIndicesError.articlePointerMismatch(id)
            }
            let titleOffset = u32(hits, at + 8)
            let variants: [LegacyTitleSegment]
            if titleOffset == UInt32.max { variants = [] }
            else if let cached = titleCache[titleOffset] { variants = cached }
            else {
                variants = try titleVariants(keys, offset: Int(titleOffset))
                titleCache[titleOffset] = variants
            }
            articles.append(LegacyArticleIndexEntry(directoryRow: row, articleID: id, relativeTartOffset: relative,
                                                    titleOffset: titleOffset == UInt32.max ? nil : titleOffset,
                                                    flags: u32(hits, at + 12), indexWithinLevel: u32(hits, at + 16),
                                                    level: hits[at + 20], titleSegments: variants))
        }
        var positions: [LegacyReferencePosition] = []
        if let parent = blocks.first(where: { $0.tag == "RTAX" }),
           let infoBlock = child("info", within: parent), let list = child("hlst", within: parent) {
            let tableInfo = try blockData(infoBlock)
            guard tableInfo.count == 6, u16(tableInfo, 0) == 0 else { throw LegacyIndicesError.invalidTable("RTAX/info") }
            let count = Int(u32(tableInfo, 2))
            guard count <= 500_000, UInt64(count) * 18 == list.length else { throw LegacyIndicesError.invalidTable("RTAX/hlst") }
            let records = try blockData(list)
            for row in 0..<count {
                let at = row * 18
                let start = u32(records, at + 2), end = u32(records, at + 10)
                guard Int(start) < sections.sections.count, Int(end) < sections.sections.count else {
                    throw LegacyIndicesError.invalidTable("RTAX/articleID")
                }
                positions.append(LegacyReferencePosition(referenceID: u16(records, at), startArticleID: start,
                                                         startCharacterOffset: u32(records, at + 6), endArticleID: end,
                                                         endCharacterOffset: u32(records, at + 14)))
            }
        }
        var ranges: [LegacyArticleReferenceRange] = []
        if let parent = blocks.first(where: { $0.tag == "ATRX" }),
           let infoBlock = child("info", within: parent), let list = child("hlst", within: parent) {
            let tableInfo = try blockData(infoBlock)
            guard tableInfo.count == 6, u16(tableInfo, 0) == 0 else { throw LegacyIndicesError.invalidTable("ATRX/info") }
            let count = Int(u32(tableInfo, 2))
            guard count <= 500_000, UInt64(count) * 8 == list.length else { throw LegacyIndicesError.invalidTable("ATRX/hlst") }
            let records = try blockData(list)
            for row in 0..<count {
                let at = row * 8, id = u32(records, at)
                guard Int(id) < sections.sections.count else { throw LegacyIndicesError.articlePointerMismatch(id) }
                ranges.append(LegacyArticleReferenceRange(articleID: id, firstReferenceID: u16(records, at + 4),
                                                          lastReferenceID: u16(records, at + 6)))
            }
        }
        var namedPositions: [LegacyNamedPosition] = []
        if let parent = blocks.first(where: { $0.tag == "CIDX" }) {
            guard let infoBlock = child("info", within: parent), let list = child("hlst", within: parent),
                  let stringBlock = child("klst", within: parent), let reverseBlock = child("coff", within: parent) else {
                throw LegacyIndicesError.invalidTable("CIDX/children")
            }
            let tableInfo = try blockData(infoBlock)
            guard tableInfo.count == 6, u16(tableInfo, 0) == 0 else { throw LegacyIndicesError.invalidTable("CIDX/info") }
            let count = Int(u32(tableInfo, 2))
            guard count <= 500_000, count == sections.sections.count,
                  UInt64(count) * 8 == list.length, UInt64(count) * 4 == reverseBlock.length else {
                throw LegacyIndicesError.invalidTable("CIDX/length")
            }
            let records = try blockData(list), strings = try blockData(stringBlock), reverse = try blockData(reverseBlock)
            var seen = Set<UInt32>()
            namedPositions.reserveCapacity(count)
            for row in 0..<count {
                if row.isMultiple(of: 256) { try Task.checkCancellation() }
                let at = row * 8, key = Int(u32(records, at)), id = u32(records, at + 4)
                guard Int(id) < count, seen.insert(id).inserted,
                      key < strings.count, let end = strings[key...].firstIndex(of: 0), end - key <= 8192 else {
                    throw LegacyIndicesError.invalidTable("CIDX/position")
                }
                namedPositions.append(LegacyNamedPosition(directoryRow: row, articleID: id,
                    label: LegacyResourceReader.decodeCP1252(strings.subdata(in: key..<end))))
            }
            for ordinal in 0..<count {
                let row = Int(u32(reverse, ordinal * 4))
                guard row < count, namedPositions[row].articleID == UInt32(ordinal) else {
                    throw LegacyIndicesError.invalidTable("CIDX/coff")
                }
            }
        } else { warnings.append("El recurso no declara CIDX; las posiciones nombradas no están disponibles.") }
        if positions.isEmpty { warnings.append("No se interpretó una tabla RTAX de posiciones de referencias.") }
        if ranges.isEmpty { warnings.append("No se interpretó una tabla ATRX de rangos de artículos.") }
        return LegacyIndicesInspection(sections: sections, articles: articles, referencePositions: positions,
                                       articleReferenceRanges: ranges, namedPositions: namedPositions, warnings: warnings)
    }

    /// A flat, complete directory retaining original AIDX rows and levels. No
    /// parent/child tree is inferred from levels whose original mapping is unknown.
    public static func articleDirectory(lsfURL: URL, lixURL: URL) throws -> LegacyArticleDirectory {
        let index = try inspect(lsfURL: lsfURL, lixURL: lixURL)
        return articleDirectory(index: index)
    }

    static func articleDirectory(index: LegacyIndicesInspection) -> LegacyArticleDirectory {
        let labels = Dictionary(uniqueKeysWithValues: index.namedPositions.map { ($0.articleID, $0.label) })
        let entries = index.articles.map { article in
            LegacyArticleDirectoryEntry(directoryRow: article.directoryRow, articleID: article.articleID,
                level: article.level, indexWithinLevel: article.indexWithinLevel, flags: article.flags,
                relativeTartOffset: article.relativeTartOffset, titleSegments: article.titleSegments,
                positionLabel: labels[article.articleID], section: index.sections.sections[Int(article.articleID)])
        }
        return LegacyArticleDirectory(entries: entries, sections: index.sections,
            namedPositionCount: index.namedPositions.count, warnings: index.warnings)
    }

    /// Resolves an exact source label with case/spacing/punctuation normalization.
    public static func resolveObservedReference(lsfURL: URL, lixURL: URL, reference: String,
                                                maximumCandidates: Int = 256) throws -> LegacyReferenceResolution {
        guard let query = LegacyObservedBibleReference.parse(reference) else { throw LegacyIndicesError.invalidObservedReference }
        let index = try inspect(lsfURL: lsfURL, lixURL: lixURL)
        return try resolve(lsfURL: lsfURL, index: index, reference: reference, chapter: query.chapter,
            normalizedKey: query.normalizedKey, translateBookNames: false, maximumCandidates: maximumCandidates)
    }

    /// Accepts human ES/EN book names and abbreviations, but matches only actual
    /// decoded source anchors. This does not reproduce the original datatype parser
    /// or convert references between versifications. Single verses only.
    public static func resolvePassage(lsfURL: URL, lixURL: URL, reference: String,
                                      maximumCandidates: Int = 256) throws -> LegacyReferenceResolution {
        guard let query = LegacyPassageQuery.parse(reference) else { throw LegacyIndicesError.invalidObservedReference }
        let index = try inspect(lsfURL: lsfURL, lixURL: lixURL)
        return try resolvePassage(lsfURL: lsfURL, index: index, query: query, maximumCandidates: maximumCandidates)
    }

    static func resolvePassage(lsfURL: URL, index: LegacyIndicesInspection, query: LegacyPassageQuery,
                                maximumCandidates: Int) throws -> LegacyReferenceResolution {
        try resolve(lsfURL: lsfURL, index: index, reference: query.original, chapter: query.chapter,
            normalizedKey: query.normalizedKey, translateBookNames: true, maximumCandidates: maximumCandidates, bookKey: query.sourceBookKey)
    }

    private static func resolve(lsfURL: URL, index: LegacyIndicesInspection, reference: String, chapter: Int,
                                 normalizedKey: String, translateBookNames: Bool,
                                 maximumCandidates: Int, bookKey: String? = nil) throws -> LegacyReferenceResolution {
        let fallback = unique(index.articleReferenceRanges.isEmpty ? index.articles.map(\.articleID) : index.articleReferenceRanges.map(\.articleID))
        let eligible = fallback.sorted()
        let numberedTitles = index.articles.filter { $0.level > 0 && $0.title.flatMap(titleNumberHint) != nil }
        let markerIDs = unique(numberedTitles.map(\.articleID)).sorted()
        func lowerBound(_ values: [UInt32], _ value: UInt32) -> Int {
            var low = 0, high = values.count
            while low < high {
                let middle = low + (high - low) / 2
                if values[middle] < value { low = middle + 1 } else { high = middle }
            }
            return low
        }
        var prioritized: [UInt32] = []
        for entry in numberedTitles where entry.title.flatMap(titleNumberHint) == chapter {
            try Task.checkCancellation()
            let marker = lowerBound(markerIDs, entry.articleID)
            let end = marker + 1 < markerIDs.count ? markerIDs[marker + 1] : UInt32(index.sections.sections.count)
            let startCandidate = lowerBound(eligible, entry.articleID), endCandidate = lowerBound(eligible, end)
            // RVR60 can put the chapter heading in one frame and its verses in
            // following frames. Physical neighbors before the next numbered
            // title are useful candidates, not an inferred parent/child contract.
            prioritized.append(contentsOf: eligible[startCandidate..<endCandidate])
        }
        // Book titles are additional work-order hints, never fabricated verse
        // destinations or a claim about AIDX hierarchy. A matching source verse
        // anchor is still required. This keeps one-chapter NT books from falling
        // behind every preceding book's chapter 1 in the bounded search.
        var bookPrioritized: [UInt32] = []
        if let bookKey {
            let books = index.articles.compactMap { entry -> (id: UInt32, key: String)? in
                guard let title = entry.title else { return nil }
                let words = title.split(whereSeparator: \.isWhitespace)
                // Human headings may include a bibliographic prefix (for
                // example “La Epístola del Apóstol San Judas”). A book-name
                // suffix only prioritizes reads; the source anchor decides.
                if (1...max(1, words.count)).contains(where: { count in
                    LegacyPassageQuery.parse(words.suffix(count).joined(separator: " ") + " 1:1")?.sourceBookKey == bookKey
                }) { return (entry.articleID, bookKey) }
                guard let query = LegacyPassageQuery.parse(title + " 1:1") else { return nil }
                return (entry.articleID, query.sourceBookKey)
            }.sorted { $0.id < $1.id }
            for (position, book) in books.enumerated() where book.key == bookKey {
                let end = books.dropFirst(position + 1).first(where: { $0.id > book.id })?.id ?? UInt32(index.sections.sections.count)
                bookPrioritized.append(contentsOf: prioritized.filter { $0 >= book.id && $0 < end })
                bookPrioritized.append(contentsOf: eligible[lowerBound(eligible, book.id)..<lowerBound(eligible, end)])
            }
        }
        // Metadata changes priority only. It never excludes another article.
        let candidates = unique(bookPrioritized + prioritized + fallback)
        let limit = min(max(maximumCandidates, 1), 4096)
        var diagnostics = index.warnings
        var examined = 0
        func key(_ value: String?) -> String? {
            guard let value else { return nil }
            if translateBookNames { return LegacyPassageQuery.sourceReference(value)?.normalizedKey }
            return LegacyObservedBibleReference.parse(value)?.normalizedKey
        }
        for id in candidates.prefix(limit) {
            try Task.checkCancellation()
            examined += 1
            do {
                let content = try LegacyContentReader.readSection(lsfURL: lsfURL, descriptor: index.sections.sections[Int(id)],
                                                                  tartEnd: index.sections.tartOffset + index.sections.tartLength)
                guard let anchor = content.anchors.first(where: { key($0.reference) == normalizedKey }),
                      let observedReference = anchor.reference else { continue }
                let position = index.referencePositions.first {
                    $0.startArticleID == id && Int($0.startCharacterOffset) == anchor.characterOffset
                }
                guard position?.endArticleID == nil || position?.endArticleID == id else {
                    throw LegacyIndicesError.crossArticleReferenceUnsupported
                }
                let next = content.anchors.first {
                    $0.reference != nil && $0.characterOffset > anchor.characterOffset && key($0.reference) != normalizedKey
                }?.characterOffset ?? content.plainText.utf16.count
                let end = position.map { Int($0.endCharacterOffset) + 1 } ?? next
                // An index interval may not consume the next distinct observed
                // verse. Corrupt or mismatched positions remain a diagnostic.
                guard end <= next else { throw LegacyIndicesError.invalidReferenceRange }
                let text = try sliceUTF16(content.plainText, start: anchor.characterOffset, end: end)
                let match = LegacyReferenceMatch(observedReference: observedReference, articleID: id, sectionOrdinal: Int(id),
                                                 startCharacterOffset: anchor.characterOffset, endCharacterOffsetExclusive: end,
                                                 referencePosition: position, text: text, warnings: content.warnings)
                return LegacyReferenceResolution(query: reference, match: match, candidatesExamined: examined,
                                                  totalCandidates: candidates.count, exhaustedCandidates: examined == candidates.count,
                                                  diagnostics: diagnostics)
            } catch is CancellationError { throw CancellationError() }
              catch { diagnostics.append("Artículo \(id): \(String(describing: error))") }
        }
        if examined < candidates.count {
            diagnostics.append("Se examinaron \(examined) de \(candidates.count) artículos candidatos. El límite no permite afirmar que el pasaje no exista.")
        }
        return LegacyReferenceResolution(query: reference, match: nil, candidatesExamined: examined,
                                          totalCandidates: candidates.count, exhaustedCandidates: examined == candidates.count,
                                          diagnostics: diagnostics)
    }

    private static func titleVariants(_ data: Data, offset: Int) throws -> [LegacyTitleSegment] {
        guard offset >= 0, offset <= data.count, 2 <= data.count - offset else { throw LegacyIndicesError.invalidTable("klst/title") }
        let count = Int(u16(data, offset))
        guard count <= 8192, count * 2 + 4 <= data.count - offset,
              u16(data, offset + 2 + count * 2) == 0 else { throw LegacyIndicesError.invalidTable("klst/title") }
        let units = (0..<count).map { u16(data, offset + 2 + $0 * 2) }
        if !units.contains(1), !units.contains(2) {
            return [LegacyTitleSegment(selectorCode: nil, text: try strictUTF16(units))]
        }
        var cursor = 0, variants: [LegacyTitleSegment] = []
        while cursor < units.count {
            if units[cursor] != 1 {
                let start = cursor
                while cursor < units.count, units[cursor] != 1, units[cursor] != 2 { cursor += 1 }
                guard cursor == units.count || units[cursor] == 1 else { throw LegacyIndicesError.invalidTable("klst/selector") }
                variants.append(LegacyTitleSegment(selectorCode: nil, text: try strictUTF16(Array(units[start..<cursor]))))
                continue
            }
            guard cursor + 2 < units.count else { throw LegacyIndicesError.invalidTable("klst/selector") }
            let locale = units[cursor + 1]
            cursor += 2
            let start = cursor
            while cursor < units.count, units[cursor] != 2 { cursor += 1 }
            guard cursor < units.count else { throw LegacyIndicesError.invalidTable("klst/selector") }
            variants.append(LegacyTitleSegment(selectorCode: locale, text: try strictUTF16(Array(units[start..<cursor]))))
            cursor += 1
        }
        return variants
    }

    private static func strictUTF16(_ units: [UInt16]) throws -> String {
        var cursor = 0, scalars = String.UnicodeScalarView()
        while cursor < units.count {
            let first = units[cursor]
            cursor += 1
            let value: UInt32
            if (0xd800...0xdbff).contains(first) {
                guard cursor < units.count, (0xdc00...0xdfff).contains(units[cursor]) else { throw LegacyIndicesError.invalidTable("UTF16") }
                value = 0x10000 + (UInt32(first - 0xd800) << 10) + UInt32(units[cursor] - 0xdc00)
                cursor += 1
            } else {
                guard !(0xdc00...0xdfff).contains(first) else { throw LegacyIndicesError.invalidTable("UTF16") }
                value = UInt32(first)
            }
            guard let scalar = UnicodeScalar(value) else { throw LegacyIndicesError.invalidTable("UTF16") }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func sliceUTF16(_ text: String, start: Int, end: Int) throws -> String {
        let units = Array(text.utf16)
        guard start >= 0, start <= end, end <= units.count else { throw LegacyIndicesError.invalidReferenceRange }
        return try strictUTF16(Array(units[start..<end]))
    }

    private static func titleNumberHint(_ text: String) -> Int? {
        // Original NCV headings include descriptions after the chapter number,
        // e.g. "Psalm 23 - ...". This only orders candidate reads; an actual
        // decoded source anchor is still required to establish the destination.
        let pieces = text.split(whereSeparator: { !$0.isASCII || !$0.isNumber })
        guard let first = pieces.first, let number = Int(first), (1...65535).contains(number) else { return nil }
        return number
    }

    private static func unique(_ values: [UInt32]) -> [UInt32] {
        var seen = Set<UInt32>()
        return values.filter { seen.insert($0).inserted }
    }
    private static func u16(_ data: Data, _ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
    }
}
