import Foundation

/// One source CIDX row. The label is an opaque position supplied by the book;
/// its punctuation is not interpreted as chapter, verse, or character offsets.
public struct LegacyNamedPosition: Sendable, Codable, Equatable {
    public let directoryRow: Int
    public let articleID: UInt32
    public let label: String
}

/// One AIDX row enriched with its checked physical destination and CIDX label.
/// Rows retain source order and identity, including multiple rows per article.
/// `level` is source metadata, not a demonstrated parent/child relationship.
public struct LegacyArticleDirectoryEntry: Sendable, Codable, Equatable, Identifiable {
    public let directoryRow: Int
    public let articleID: UInt32
    public let level: UInt8
    public let indexWithinLevel: UInt32
    public let flags: UInt32
    public let relativeTartOffset: UInt32
    public let titleSegments: [LegacyTitleSegment]
    public let positionLabel: String?
    public let section: LegacySectionDescriptor
    public var id: Int { directoryRow }
    public var sectionOrdinal: Int { section.ordinal }
    public var title: String? { titleSegments.isEmpty ? nil : titleSegments.map(\.text).joined() }
    /// The fallback is explicitly a navigation label, never substituted book text.
    public var displayTitle: String { title ?? positionLabel ?? "Artículo \(articleID + 1)" }
}

public struct LegacyArticleDirectory: Sendable, Codable, Equatable {
    public let entries: [LegacyArticleDirectoryEntry]
    public let sections: LegacySectionIndex
    public let namedPositionCount: Int
    public let warnings: [String]

    /// More than one source row can target a physical section. Preserve all of them.
    public func entries(forSectionOrdinal ordinal: Int) -> [LegacyArticleDirectoryEntry] {
        entries.filter { $0.sectionOrdinal == ordinal }
    }

    public func entry(forDirectoryRow row: Int) -> LegacyArticleDirectoryEntry? {
        guard entries.indices.contains(row), entries[row].directoryRow == row else { return nil }
        return entries[row]
    }
}

/// A human query names one verse, without defining a canon or versification.
/// Aliases are a presentation convenience. A reader still requires an actual
/// source anchor before returning a match; no chapter/verse existence is inferred.
public struct LegacyPassageQuery: Sendable, Codable, Equatable {
    public let original: String
    public let book: String
    public let chapter: Int
    public let verse: Int
    public let sourceBookKey: String
    public var normalizedKey: String { "\(sourceBookKey) \(chapter):\(verse)" }
    public var displayReference: String { "\(book) \(chapter):\(verse)" }

    public static func parse(_ value: String) -> LegacyPassageQuery? {
        if let serialized = serializedBibleReference(value) { return serialized }
        guard value.utf16.count <= 512 else { return nil }
        let cleaned = value.replacingOccurrences(of: #"(?i)\b(?:cap[ií]tulo|chapter|vers[ií]culo|verse|cap|vers|v)(?:\.|\b)\s*"#,
                                                 with: " ", options: .regularExpression)
        let pattern = #"^\s*((?:[1-3][.ºª°]?\s*|[Ii]{1,3}\s+)?[\p{L}.]+(?:\s+[\p{L}.]+)*)\s*(\d+)\s*(?:[:.,;：．，/]|\s)\s*(\d+)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let groups = expression.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let bookRange = Range(groups.range(at: 1), in: cleaned),
              let chapterRange = Range(groups.range(at: 2), in: cleaned),
              let verseRange = Range(groups.range(at: 3), in: cleaned),
              let chapter = Int(cleaned[chapterRange]), (1...65535).contains(chapter),
              let verse = Int(cleaned[verseRange]), (1...65535).contains(verse) else { return nil }
        let book = String(cleaned[bookRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return LegacyPassageQuery(original: value, book: book, chapter: chapter, verse: verse,
                                  sourceBookKey: aliases[normalizedBookName(book)] ?? normalizedBookName(book))
    }

    /// A chapter-only navigation request opens its first observed verse. Source
    /// anchors use the separate strict source parser, avoiding ambiguities.
    public static func navigationInput(_ value: String) -> LegacyPassageQuery? {
        parse(value) ?? sourceReference(value) ?? parse(value + ":1")
    }

    private static func observedQuery(_ reference: LegacyObservedBibleReference) -> Self {
        let book = reference.bookCode
        let normalized = normalizedBookName(book)
        return LegacyPassageQuery(original: reference.original, book: book, chapter: reference.chapter, verse: reference.verse,
                                  sourceBookKey: aliases[normalized] ?? normalized)
    }

    /// Source CRefRun2 strings use the Bible datatype's book identifiers, not
    /// Protestant ordinal numbers (Matthew is 61; Revelation is 87). The
    /// edition suffix is retained in `original`; this matches the same address
    /// in another edition, without claiming a versification conversion.
    private static func serializedBibleReference(_ value: String) -> Self? {
        guard value.utf16.count <= 512 else { return nil }
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let scheme = parts[0].split(separator: "+", omittingEmptySubsequences: false)
        guard (1...2).contains(scheme.count), scheme[0] == "bible",
              scheme.count == 1 || (!scheme[1].isEmpty && scheme[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })),
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let id = Int(parts[1]), let book = serializedBooks[id],
              let chapter = Int(parts[2]), (1...65535).contains(chapter),
              let verse = Int(parts[3]), (1...65535).contains(verse) else { return nil }
        return Self(original: value, book: book, chapter: chapter, verse: verse, sourceBookKey: book.lowercased())
    }

    /// A few legacy source labels omit the chapter for one-chapter books.
    /// User queries retain their existing explicit chapter:verse syntax.
    public static func sourceReference(_ value: String) -> Self? {
        if let parsed = serializedBibleReference(value) { return parsed }
        if let observed = LegacyObservedBibleReference.parse(value) { return observedQuery(observed) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let split = trimmed.lastIndex(where: { $0.isWhitespace }),
              let verse = Int(trimmed[trimmed.index(after: split)...]), (1...65535).contains(verse),
              let observed = LegacyObservedBibleReference.parse(String(trimmed[..<split]) + " 1:\(verse)"),
              case let parsed = observedQuery(observed),
              ["ob", "phm", "2jn", "3jn", "jud"].contains(parsed.sourceBookKey) else { return nil }
        return parsed
    }

    private static let serializedBooks: [Int: String] = {
        let old = ["Ge", "Ex", "Le", "Nu", "Dt", "Jos", "Jdg", "Ru", "1Sa", "2Sa", "1Ki", "2Ki", "1Ch", "2Ch", "Ezr", "Ne", "Es", "Job", "Ps", "Pr", "Ec", "So", "Is", "Je", "La", "Eze", "Da", "Ho", "Joe", "Am", "Ob", "Jon", "Mic", "Na", "Hab", "Zep", "Hag", "Zec", "Mal"]
        let new = ["Mt", "Mk", "Lk", "Jn", "Ac", "Ro", "1Co", "2Co", "Ga", "Eph", "Php", "Col", "1Th", "2Th", "1Ti", "2Ti", "Tt", "Phm", "Heb", "Jas", "1Pe", "2Pe", "1Jn", "2Jn", "3Jn", "Jud", "Re"]
        return Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.offset + 1, $0.element) } + new.enumerated().map { ($0.offset + 61, $0.element) })
    }()

    /// Exact normalization for an unlisted source label remains available. Unknown
    /// codes are preserved, so a noncanonical book can resolve its own anchor.
    static func key(for reference: LegacyObservedBibleReference) -> String {
        let normalized = normalizedBookName(reference.bookCode)
        return "\(aliases[normalized] ?? normalized) \(reference.chapter):\(reference.verse)"
    }

    private static func normalizedBookName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().filter { !$0.isWhitespace && !".ºª°".contains($0) }
    }

    // Spellings only: these lists contain no protected book content, verse text,
    // verse counts, translation tables, or guessed numeric reference identifiers.
    private static let aliasGroups: [(String, [String])] = [
        ("tob", ["tob", "tobit", "tobias", "tobías"]),
        ("jdt", ["jdt", "judit", "judith"]),
        ("wis", ["wis", "wisdom", "sab", "sabiduría", "sabedoria"]),
        ("sir", ["sir", "sirach", "eclesiástico", "eclesiastico"]),
        ("bar", ["bar", "baruch", "baruc"]),
        ("1ma", ["1ma", "1mac", "1macc", "1maccabees", "1macabeos"]),
        ("2ma", ["2ma", "2mac", "2macc", "2maccabees", "2macabeos"]),
        ("1esd", ["1esd", "1esdras"]),
        ("2esd", ["2esd", "2esdras"]),
        ("prman", ["prman", "prayer of manasseh", "oración de manasés"]),
        ("ge", ["ge", "gen", "gn", "genesis", "génesis"]),
        ("ex", ["ex", "exo", "exod", "exodus", "éxodo"]),
        ("le", ["le", "lev", "lv", "leviticus", "levítico"]),
        ("nu", ["nu", "num", "nm", "numbers", "números"]),
        ("dt", ["dt", "de", "deut", "deuteronomy", "deuteronomio"]),
        ("jos", ["jos", "josh", "joshua", "josué"]),
        ("jdg", ["jdg", "judg", "jue", "jueces", "judges"]),
        ("ru", ["ru", "rut", "ruth"]),
        ("1sa", ["1sa", "1sam", "1samuel", "i samuel"]),
        ("2sa", ["2sa", "2sam", "2samuel", "ii samuel"]),
        ("1ki", ["1ki", "1kgs", "1kings", "1re", "1rey", "1reyes", "i reyes"]),
        ("2ki", ["2ki", "2kgs", "2kings", "2re", "2rey", "2reyes", "ii reyes"]),
        ("1ch", ["1ch", "1chr", "1chronicles", "1cr", "1cro", "1crónicas", "i crónicas"]),
        ("2ch", ["2ch", "2chr", "2chronicles", "2cr", "2cro", "2crónicas", "ii crónicas"]),
        ("ezr", ["ezr", "ezra", "esd", "esdras"]),
        ("ne", ["ne", "neh", "nehemiah", "nehemías"]),
        ("es", ["es", "est", "esth", "esther", "ester"]),
        ("job", ["job", "jb"]),
        ("ps", ["ps", "psa", "psalm", "psalms", "sal", "salmo", "salmos"]),
        ("pr", ["pr", "pro", "prov", "proverbs", "proverbios"]),
        ("ec", ["ec", "ecc", "eccl", "ecclesiastes", "eclesiastés"]),
        ("so", ["so", "sos", "song", "song of songs", "song of solomon", "cnt", "cant", "cantares", "cantar de los cantares"]),
        ("is", ["is", "isa", "isaiah", "isaías"]),
        ("je", ["je", "jer", "jeremiah", "jeremías"]),
        ("la", ["la", "lam", "lamentations", "lamentaciones"]),
        ("eze", ["eze", "ezek", "ez", "ezekiel", "ezequiel"]),
        ("da", ["da", "dan", "dn", "daniel"]),
        ("ho", ["ho", "hos", "hosea", "ose", "oseas"]),
        ("joe", ["joe", "joel", "jl"]),
        ("am", ["am", "amos", "amós"]),
        ("ob", ["ob", "obad", "obadiah", "abd", "abdías"]),
        ("jon", ["jon", "jonah", "jonás"]),
        ("mic", ["mic", "mi", "micah", "miq", "miqueas"]),
        ("na", ["na", "nah", "nahum", "nahúm"]),
        ("hab", ["hab", "habakkuk", "habacuc"]),
        ("zep", ["zep", "zeph", "zephaniah", "sof", "sofonías"]),
        ("hag", ["hag", "haggai", "ag", "hageo"]),
        ("zec", ["zec", "zech", "zechariah", "zac", "zacarías"]),
        ("mal", ["mal", "malachi", "malaquías"]),
        ("mt", ["mt", "mat", "matt", "matthew", "mateo"]),
        ("mk", ["mk", "mr", "mar", "mark", "marcos"]),
        ("lk", ["lk", "lc", "lu", "luk", "luke", "lucas"]),
        ("jn", ["jn", "joh", "john", "jua", "juan"]),
        ("ac", ["ac", "act", "acts", "hch", "hech", "hechos"]),
        ("ro", ["ro", "rom", "romans", "romanos"]),
        ("1co", ["1co", "1cor", "1corinthians", "1corintios", "i corintios"]),
        ("2co", ["2co", "2cor", "2corinthians", "2corintios", "ii corintios"]),
        ("ga", ["ga", "gal", "galatians", "gálatas"]),
        ("eph", ["eph", "ef", "ephes", "ephesians", "efesios"]),
        ("php", ["php", "phil", "philip", "philippians", "fil", "filipenses"]),
        ("col", ["col", "colossians", "colosenses"]),
        ("1th", ["1th", "1thess", "1thessalonians", "1ts", "1tes", "1tesalonicenses", "i tesalonicenses"]),
        ("2th", ["2th", "2thess", "2thessalonians", "2ts", "2tes", "2tesalonicenses", "ii tesalonicenses"]),
        ("1ti", ["1ti", "1tim", "1timothy", "1timoteo", "i timoteo"]),
        ("2ti", ["2ti", "2tim", "2timothy", "2timoteo", "ii timoteo"]),
        ("tt", ["tt", "tit", "titus", "tito"]),
        ("phm", ["phm", "philem", "philemon", "flm", "filemón"]),
        ("heb", ["heb", "hebrews", "hebreos"]),
        ("jas", ["jas", "jam", "james", "stg", "sant", "santiago"]),
        ("1pe", ["1pe", "1pet", "1peter", "1pedro", "i pedro"]),
        ("2pe", ["2pe", "2pet", "2peter", "2pedro", "ii pedro"]),
        ("1jn", ["1jn", "1jo", "1john", "1juan", "i juan"]),
        ("2jn", ["2jn", "2john", "2juan", "ii juan"]),
        ("3jn", ["3jn", "3john", "3juan", "iii juan"]),
        ("jud", ["jud", "jude", "judas"]),
        ("re", ["re", "rev", "revelation", "ap", "apo", "apoc", "apocalipsis"])
    ]
    private static let aliases: [String: String] = {
        var result: [String: String] = [:]
        for (key, names) in aliasGroups {
            for name in names { result[normalizedBookName(name)] = key }
        }
        return result
    }()
}
