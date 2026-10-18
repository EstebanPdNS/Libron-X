import Foundation

public enum LibrarySearchUnit: String, CaseIterable, Sendable, Codable {
    case article, bibleVerse
}

public struct LibrarySearchBudget: Hashable, Sendable {
    public var maximumDurationSeconds: Double
    public var maximumArticles: Int
    public var maximumResults: Int
    public var maximumOccurrences: Int
    public var snippetUTF16: Int
    public var progressBatchSize: Int

    public init(maximumDurationSeconds: Double = 60, maximumArticles: Int = 20_000,
                maximumResults: Int = 500, maximumOccurrences: Int = 20_000,
                snippetUTF16: Int = 240, progressBatchSize: Int = 64) {
        self.maximumDurationSeconds = maximumDurationSeconds
        self.maximumArticles = maximumArticles
        self.maximumResults = maximumResults
        self.maximumOccurrences = maximumOccurrences
        self.snippetUTF16 = snippetUTF16
        self.progressBatchSize = progressBatchSize
    }
}

public enum LibrarySearchLimit: String, Sendable, Codable {
    case duration, articles, results, occurrences
}

public enum LibrarySearchResourceStatus: String, Sendable, Codable {
    case complete, partial, incompatible, failed, notExamined
}

public struct LibrarySearchCounters: Hashable, Sendable {
    /// Articles ruled out by a conservative, source-bound candidate index.
    public var articlesRuledOutByIndex = 0
    public var resourcesTotal = 0
    public var resourcesExamined = 0
    public var resourcesPrepared = 0
    public var resourcesCompleted = 0
    public var resourcesIncompatible = 0
    public var resourcesFailed = 0
    /// Exact only for successfully inspected resources; see unknown totals below.
    public var articlesTotalKnown = 0
    public var resourcesWithUnknownArticleTotal = 0
    public var articlesExamined = 0
    public var articlesDecoded = 0
    public var articlesFailed = 0
    public var matchingArticles = 0
    /// Source-anchored verse intervals evaluated/accepted in bibleVerse mode.
    public var versesExamined = 0
    public var matchingVerses = 0
    public var versesExcludedByRange = 0
    /// Positive text ranges found in examined articles, before report truncation.
    public var occurrencesObserved = 0
    public var occurrencesReturned = 0
    public var resultsReturned = 0

    public init() {}
}

public struct LibrarySearchResourceReport: Hashable, Sendable, Identifiable {
    public var versesExcludedByRange = 0
    public var articlesRuledOutByIndex = 0
    public let resourceID: String
    public let resourceTitle: String
    public let format: ResourceFormat
    public var status: LibrarySearchResourceStatus
    public var totalArticles: Int?
    public var articlesExamined: Int
    public var articlesDecoded: Int
    public var articlesFailed: Int
    public var matchingArticles: Int
    public var versesExamined: Int
    public var matchingVerses: Int
    public var occurrencesObserved: Int
    public var resultsReturned: Int
    public var warnings: [String]
    public var errors: [LibrarySearchArticleError]
    public var id: String { resourceID }

    init(resource: LibraryResource) {
        resourceID = resource.id
        resourceTitle = resource.title
        format = resource.format
        status = .notExamined
        totalArticles = nil
        articlesExamined = 0
        articlesDecoded = 0
        articlesFailed = 0
        matchingArticles = 0
        versesExamined = 0
        matchingVerses = 0
        occurrencesObserved = 0
        resultsReturned = 0
        warnings = []
        errors = []
    }
}

public struct LibrarySearchArticleError: Hashable, Sendable {
    public let sectionOrdinal: Int?
    public let code: String
    public let message: String
}

public struct LibrarySearchSnippet: Hashable, Sendable {
    public let text: String
    public let rangeInArticle: SearchTextRange
    /// UTF-16 ranges relative to snippet.text, not the full article.
    public let highlightRanges: [SearchTextRange]
    public let omittedPrefix: Bool
    public let omittedSuffix: Bool
}

public struct LibrarySearchResult: Hashable, Sendable, Identifiable {
    public let resourceID: String
    public let resourceTitle: String
    public let sectionOrdinal: Int
    public let articleTitle: String
    public let hitCount: Int
    public let hits: [TextSearchHit]
    public let snippet: LibrarySearchSnippet
    /// SHA-256 of the exact decoded String's UTF-8 bytes. Re-read and compare
    /// before applying UTF-16 offsets; canonical equivalents can differ in layout.
    public let decodedTextSHA256: String
    public let sourceStamps: [LibrarySearchFileStamp]
    public let presentationWarnings: [String]
    public let bibleReference: String?
    public let verseRange: SearchTextRange?
    public var externalHits: [TextSearchExternalHit] = []
    public var id: String {
        resourceID + "#section=" + String(sectionOrdinal)
            + (verseRange.map { "#verse=" + String($0.location) } ?? "")
    }
}

public struct LibrarySearchProgress: Sendable {
    public let counters: LibrarySearchCounters
    public let currentResourceTitle: String?
    public let elapsedSeconds: Double
}

public struct LibrarySearchReport: Sendable {
    public var bibleRange: BibleSearchRange? = nil
    public let unit: LibrarySearchUnit
    public let results: [LibrarySearchResult]
    public let resourceReports: [LibrarySearchResourceReport]
    public let counters: LibrarySearchCounters
    public let limitReason: LibrarySearchLimit?
    public let elapsedSeconds: Double
    /// All requested resources/articles were decoded/evaluated with no omitted
    /// formats, read/evaluation failures or budget stops. This is not index parity.
    public let coverageComplete: Bool
    public var truncated: Bool { limitReason != nil }
    public let scopeDescription: String
}

public enum LibrarySearchError: Error, LocalizedError, Equatable, Sendable {
    case invalidBudget
    case duplicateResourceID(String)
    case invalidArticleDirectory
    case invalidVerseDirectory

    public var errorDescription: String? {
        switch self {
        case .invalidBudget: "Los presupuestos de búsqueda deben ser positivos y estar dentro de los límites seguros."
        case let .duplicateResourceID(id): "El ámbito contiene dos veces el mismo recurso: \(id)."
        case .invalidArticleDirectory: "El proveedor de texto devolvió artículos duplicados o posiciones inválidas."
        case .invalidVerseDirectory: "Las referencias bíblicas contienen límites ambiguos o posiciones inválidas."
        }
    }
}

public struct LibrarySearchArticleDescriptor: Hashable, Sendable, Codable {
    public let sectionOrdinal: Int
    public let title: String
    public let sourceTitles: [String]?
    public init(sectionOrdinal: Int, title: String, sourceTitles: [String]? = nil) {
        self.sectionOrdinal = sectionOrdinal
        self.title = title; self.sourceTitles = sourceTitles
    }
}

public struct LibrarySearchFileStamp: Hashable, Sendable, Codable {
    public let url: URL
    public let size: UInt64
    public let modified: Date
    public let fileNumber: UInt64?
    public init(url: URL, size: UInt64, modified: Date, fileNumber: UInt64? = nil) {
        self.url = url
        self.size = size
        self.modified = modified
        self.fileNumber = fileNumber
    }
    public static func capture(_ url: URL) throws -> Self {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { throw LegacyIndicesError.sourceChanged }
        return .init(url: url, size: size.uint64Value, modified: modified,
                     fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
    public static func verify(_ stamps: [Self]) throws {
        for original in stamps {
            do {
                guard try capture(original.url) == original else { throw LegacyIndicesError.sourceChanged }
            } catch is CancellationError { throw CancellationError() }
            catch { throw LegacyIndicesError.sourceChanged }
        }
    }
}

public struct LibrarySearchPreparedResource: Sendable, Codable {
    /// nil leaves capabilities unknown; a declared profile can reject unsupported
    /// fields once, without decoding thousands of articles merely to fail each.
    public let availableFields: [SearchField]?
    /// Producer-owned projection contract. A changed decoder/link projection
    /// must invalidate cached articles even when the original files did not change.
    public let projectionVersion: String?
    public let articles: [LibrarySearchArticleDescriptor]
    public let sourceStamps: [LibrarySearchFileStamp]
    public let warnings: [String]
    public init(articles: [LibrarySearchArticleDescriptor], sourceStamps: [LibrarySearchFileStamp] = [],
                warnings: [String] = [], projectionVersion: String? = nil, availableFields: [SearchField]? = nil) {
        self.availableFields = availableFields
        self.projectionVersion = projectionVersion
        self.articles = articles
        self.sourceStamps = sourceStamps
        self.warnings = warnings
    }
}

public struct LibrarySearchDecodedArticle: Sendable, Codable {
    public let lexicalBreaks: [Int]?
    public let fieldDirectory: SearchFieldDirectory?
    public let referenceLinks: [BibleReferenceSourceLink]?
    public let text: String
    /// Article extent within a shared rendered page. Coordinates and the hash
    /// remain relative to the complete visible page, including preceding articles.
    public let searchRange: SearchTextRange?
    public let warnings: [String]
    public let bibleVerses: [LibrarySearchBibleVerse]
    public let referenceAnchors: [LegacyReferenceAnchor]
    public init(text: String, warnings: [String] = [], bibleVerses: [LibrarySearchBibleVerse] = [],
                referenceAnchors: [LegacyReferenceAnchor] = [], searchRange: SearchTextRange? = nil,
                referenceLinks: [BibleReferenceSourceLink]? = nil, fieldDirectory: SearchFieldDirectory? = nil, lexicalBreaks: [Int]? = nil) {
        self.lexicalBreaks = lexicalBreaks
        self.fieldDirectory = fieldDirectory
        self.referenceLinks = referenceLinks
        self.text = text; self.warnings = warnings; self.bibleVerses = bibleVerses; self.referenceAnchors = referenceAnchors
        self.searchRange = searchRange
    }
}

/// Injectable read-only boundary. Production uses the existing stamp-aware
/// LegacyContentService; synthetic fixtures never need commercial book content.
public protocol LibrarySearchContentProvider: Sendable {
    func supports(_ resource: LibraryResource) async -> Bool
    func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource
    func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor,
              prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle
    func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws
    /// A conservative superset of possibly matching articles. nil means every
    /// article must be evaluated. Consumers still verify each candidate's text.
    func candidates(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource,
                    query: SearchQuery, options: TextSearchOptions, unit: LibrarySearchUnit) async throws -> Set<Int>?
}

public extension LibrarySearchContentProvider {
    func candidates(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource,
                    query: SearchQuery, options: TextSearchOptions, unit: LibrarySearchUnit) async throws -> Set<Int>? { nil }
    func supports(_ resource: LibraryResource) async -> Bool {
        [.legacyLSF, .libronixLLS].contains(resource.format)
    }
}
