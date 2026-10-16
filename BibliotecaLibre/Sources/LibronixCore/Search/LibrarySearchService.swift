import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Read-only linear search over decoded legacy articles (physical sections).
/// No book text or snippets are persisted. Results explicitly describe omissions.
public actor LibrarySearchService {
    private let provider: any LibrarySearchContentProvider

    public init(contentService: LegacyContentService = LegacyContentService()) {
        provider = LibrarySearchReader(contentService: contentService)
    }

    public init(provider: any LibrarySearchContentProvider) { self.provider = provider }

    public func search(resources: [LibraryResource], query: SearchQuery,
                       options: TextSearchOptions = TextSearchOptions(),
                       unit: LibrarySearchUnit = .article,
                       budget: LibrarySearchBudget = LibrarySearchBudget(),
                       onProgress: (@Sendable (LibrarySearchProgress) async -> Void)? = nil) async throws -> LibrarySearchReport {
        try validate(budget)
        try Task.checkCancellation()
        // Validate evaluator options before classifying any source as a failed read.
        _ = try TextSearchEngine.search(query: query, in: "", options: options)
        var ids = Set<String>()
        for resource in resources {
            guard ids.insert(resource.id).inserted else { throw LibrarySearchError.duplicateResourceID(resource.id) }
        }
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Double {
            let components = start.duration(to: clock.now).components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        }
        var counters = LibrarySearchCounters()
        counters.resourcesTotal = resources.count
        counters.resourcesWithUnknownArticleTotal = resources.count
        var resourceReports = resources.map(LibrarySearchResourceReport.init)
        var results: [LibrarySearchResult] = []
        var limit: LibrarySearchLimit?
        var preparedSources: [(LibraryResource, LibrarySearchPreparedResource)] = []

        // Opaque/invalid resources remain visible even when a later scan hits a budget.
        for index in resources.indices {
            let resource = resources[index]
            if ![ResourceFormat.legacyLSF, .libronixLLS].contains(resource.format) || resource.support == .invalidFile {
                resourceReports[index].status = .incompatible
                resourceReports[index].warnings = [resource.support == .invalidFile
                    ? "El recurso fue importado como archivo inválido; no se buscó su contenido."
                    : "El lector de contenido de \(resource.format.displayName) aún no está implementado; no se buscó este recurso."]
                counters.resourcesExamined += 1
                counters.resourcesIncompatible += 1
            }
        }

        func budgetLimit(includeArticles: Bool = true) -> LibrarySearchLimit? {
            if elapsed() >= budget.maximumDurationSeconds { return .duration }
            if includeArticles && counters.articlesExamined >= budget.maximumArticles { return .articles }
            if results.count >= budget.maximumResults { return .results }
            if counters.occurrencesReturned >= budget.maximumOccurrences { return .occurrences }
            return nil
        }

        try await emitProgress(counters: counters, title: nil, elapsedSeconds: elapsed(), onProgress: onProgress)

        resourceLoop: for index in resources.indices {
            try Task.checkCancellation()
            if resourceReports[index].status == .incompatible { continue }
            if let reached = budgetLimit() { limit = reached; break }
            let resource = resources[index]
            counters.resourcesExamined += 1
            let prepared: LibrarySearchPreparedResource
            do {
                prepared = try await provider.prepare(resource)
                let ordinals = prepared.articles.map(\.sectionOrdinal)
                guard !ordinals.isEmpty, ordinals.count <= 500_000,
                      ordinals.allSatisfy({ $0 >= 0 }), Set(ordinals).count == ordinals.count else {
                    throw LibrarySearchError.invalidArticleDirectory
                }
                try await provider.verifyUnchanged(resource, prepared: prepared)
            } catch {
                try propagateCritical(error)
                resourceReports[index].status = .failed
                resourceReports[index].errors.append(errorRecord(error, ordinal: nil))
                counters.resourcesFailed += 1
                try await emitProgress(counters: counters, title: resource.title, elapsedSeconds: elapsed(), onProgress: onProgress)
                continue
            }
            preparedSources.append((resource, prepared))
            counters.resourcesPrepared += 1
            counters.resourcesWithUnknownArticleTotal -= 1
            counters.articlesTotalKnown += prepared.articles.count
            resourceReports[index].totalArticles = prepared.articles.count
            resourceReports[index].warnings = prepared.warnings
            resourceReports[index].status = .partial
            let articles = prepared.articles.sorted { $0.sectionOrdinal < $1.sectionOrdinal }
            for article in articles {
                try Task.checkCancellation()
                if let reached = budgetLimit() { limit = reached; break resourceLoop }
                counters.articlesExamined += 1
                resourceReports[index].articlesExamined += 1
                do {
                    try await provider.verifyUnchanged(resource, prepared: prepared)
                    let content = try await provider.read(resource, article: article, prepared: prepared)
                    try await provider.verifyUnchanged(resource, prepared: prepared)
                    counters.articlesDecoded += 1
                    resourceReports[index].articlesDecoded += 1
                    if elapsed() >= budget.maximumDurationSeconds { limit = .duration; break resourceLoop }
                    let verses: [LibrarySearchBibleVerse]
                    if unit == .bibleVerse {
                        verses = content.referenceAnchors.isEmpty ? content.bibleVerses
                            : try BibleVerseText.intervals(text: content.text, anchors: content.referenceAnchors)
                        try BibleVerseText.validate(verses, in: content.text)
                    } else { verses = [] }
                    let intervals: [LibrarySearchBibleVerse?] = unit == .article ? [nil] : verses.map { Optional($0) }
                    var articleMatched = false
                    var fingerprint: String?
                    for verse in intervals {
                        try Task.checkCancellation()
                        if let reached = budgetLimit(includeArticles: false) { limit = reached; break resourceLoop }
                        if verse != nil {
                            counters.versesExamined += 1
                            resourceReports[index].versesExamined += 1
                        }
                        let evaluationText = verse.map { (content.text as NSString).substring(with: $0.range.nsRange) } ?? content.text
                        let match = try TextSearchEngine.search(query: query, in: evaluationText, options: options)
                        if elapsed() >= budget.maximumDurationSeconds { limit = .duration; break resourceLoop }
                        if match.matchesQuery {
                            if !articleMatched {
                                counters.matchingArticles += 1
                                resourceReports[index].matchingArticles += 1
                                articleMatched = true
                            }
                            if verse != nil {
                                counters.matchingVerses += 1
                                resourceReports[index].matchingVerses += 1
                            }
                            counters.occurrencesObserved += match.hitCount
                            resourceReports[index].occurrencesObserved += match.hitCount
                            let remaining = budget.maximumOccurrences - counters.occurrencesReturned
                            let retained = match.hits.prefix(remaining).map { hit in
                                TextSearchHit(range: .init(location: hit.range.location + (verse?.range.location ?? 0),
                                    length: hit.range.length), operands: hit.operands)
                            }
                            if fingerprint == nil { fingerprint = Self.textFingerprint(content.text) }
                            results.append(.init(resourceID: resource.id, resourceTitle: resource.title,
                                sectionOrdinal: article.sectionOrdinal, articleTitle: verse?.reference ?? article.title,
                                hitCount: match.hitCount, hits: retained,
                                snippet: Self.snippet(content.text, hits: retained, maximumUTF16: budget.snippetUTF16, within: verse?.range),
                                decodedTextSHA256: fingerprint!, sourceStamps: prepared.sourceStamps,
                                presentationWarnings: content.warnings,
                                bibleReference: verse?.normalizedReference, verseRange: verse?.range))
                            counters.resultsReturned += 1
                            counters.occurrencesReturned += retained.count
                            resourceReports[index].resultsReturned += 1
                            if retained.count < match.hitCount { limit = .occurrences; break resourceLoop }
                        }
                    }
                } catch {
                    try propagateCritical(error)
                    counters.articlesFailed += 1
                    resourceReports[index].articlesFailed += 1
                    resourceReports[index].errors.append(errorRecord(error, ordinal: article.sectionOrdinal))
                }
                if counters.articlesExamined.isMultiple(of: budget.progressBatchSize) {
                    try await emitProgress(counters: counters, title: resource.title, elapsedSeconds: elapsed(), onProgress: onProgress)
                    try await provider.verifyUnchanged(resource, prepared: prepared)
                }
            }
            if resourceReports[index].articlesExamined == articles.count {
                resourceReports[index].status = resourceReports[index].articlesFailed == 0 ? .complete : .partial
                if unit == .bibleVerse && resourceReports[index].versesExamined == 0 && resourceReports[index].articlesFailed == 0 {
                    resourceReports[index].status = .incompatible
                    resourceReports[index].warnings.append("El contenido leído no contiene intervalos de versículos compatibles; no permite afirmar ausencia de coincidencias bíblicas.")
                    counters.resourcesIncompatible += 1
                }
                if resourceReports[index].status == .complete { counters.resourcesCompleted += 1 }
            }
            try await emitProgress(counters: counters, title: resource.title, elapsedSeconds: elapsed(), onProgress: onProgress)
            try await provider.verifyUnchanged(resource, prepared: prepared)
        }
        counters.resourcesWithUnknownArticleTotal = resourceReports.filter { $0.totalArticles == nil }.count
        try await emitProgress(counters: counters, title: nil, elapsedSeconds: elapsed(), onProgress: onProgress)
        // Also catch a source changing after its own last article while another
        // book is being scanned or the progress callback is running.
        for (resource, prepared) in preparedSources {
            try await provider.verifyUnchanged(resource, prepared: prepared)
        }
        let complete = limit == nil && counters.resourcesCompleted == counters.resourcesTotal
            && counters.articlesFailed == 0
        return .init(unit: unit, results: results, resourceReports: resourceReports, counters: counters,
            limitReason: limit, elapsedSeconds: elapsed(), coverageComplete: complete,
            scopeDescription: unit == .article
                ? "Búsqueda lineal por artículo legado/sección física, sobre texto realmente decodificado. Los rangos pertenecen a ese texto UTF-16; no son offsets de índices legados ni búsqueda de lemas/Strong."
                : "Búsqueda lineal dentro de intervalos nombrados por anclas bíblicas de tipo 2, hasta la siguiente referencia distinta o fin del artículo. Excluye prefijos sin referencia y no une versículos entre artículos. Los rangos UTF-16 y el hash corresponden al artículo completo. Índices, límites RPOS y equivalencia general con Libronix continúan pendientes.")
    }

    private func emitProgress(counters: LibrarySearchCounters, title: String?, elapsedSeconds: Double,
                              onProgress: (@Sendable (LibrarySearchProgress) async -> Void)?) async throws {
        try Task.checkCancellation()
        let snapshot = LibrarySearchProgress(counters: counters, currentResourceTitle: title, elapsedSeconds: elapsedSeconds)
        if let onProgress { await onProgress(snapshot) }
        try Task.checkCancellation()
    }

    private func validate(_ budget: LibrarySearchBudget) throws {
        guard budget.maximumDurationSeconds.isFinite, budget.maximumDurationSeconds > 0,
              budget.maximumDurationSeconds <= 3_600,
              budget.maximumArticles > 0, budget.maximumArticles <= 500_000,
              budget.maximumResults > 0, budget.maximumResults <= 10_000,
              budget.maximumOccurrences > 0, budget.maximumOccurrences <= 1_000_000,
              budget.snippetUTF16 > 0, budget.snippetUTF16 <= 4_096,
              budget.progressBatchSize > 0, budget.progressBatchSize <= 10_000 else {
            throw LibrarySearchError.invalidBudget
        }
    }

    public static func textFingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func propagateCritical(_ error: any Error) throws {
        if error is CancellationError { throw CancellationError() }
        if let changed = error as? LegacyIndicesError, changed == .sourceChanged { throw changed }
    }

    private func errorRecord(_ error: any Error, ordinal: Int?) -> LibrarySearchArticleError {
        let family: String
        if error is LegacyContentError { family = "legacy-content" }
        else if error is LegacyIndicesError { family = "legacy-index" }
        else if error is TextSearchError { family = "text-evaluation" }
        else if error is LibrarySearchError { family = "search-provider" }
        else { family = "source-read" }
        return .init(sectionOrdinal: ordinal, code: family, message: error.localizedDescription)
    }

    /// Limits both ends to grapheme boundaries. A pathological grapheme longer
    /// than the entire snippet budget is omitted, rather than split or overrun.
    static func snippet(_ source: String, hits: [TextSearchHit], maximumUTF16: Int,
                        within interval: SearchTextRange? = nil) -> LibrarySearchSnippet {
        if let interval {
            let slice = (source as NSString).substring(with: interval.nsRange)
            let localHits = hits.map { TextSearchHit(range: .init(location: $0.range.location - interval.location,
                length: $0.range.length), operands: $0.operands) }
            let local = snippet(slice, hits: localHits, maximumUTF16: maximumUTF16)
            return .init(text: local.text,
                rangeInArticle: .init(location: local.rangeInArticle.location + interval.location, length: local.rangeInArticle.length),
                highlightRanges: local.highlightRanges, omittedPrefix: local.omittedPrefix, omittedSuffix: local.omittedSuffix)
        }
        let text = source as NSString
        let length = text.length
        guard length > 0 else {
            return .init(text: "", rangeInArticle: .init(location: 0, length: 0),
                         highlightRanges: [], omittedPrefix: false, omittedSuffix: false)
        }
        let focus = hits.first?.range.location ?? 0
        let context = maximumUTF16 / 3
        var start = max(0, min(length, focus - context))
        var end = min(length, start + maximumUTF16)
        if end == length { start = max(0, end - maximumUTF16) }
        if start < length {
            let cluster = text.rangeOfComposedCharacterSequence(at: start)
            if cluster.location < start { start = NSMaxRange(cluster) }
        }
        if end < length {
            let cluster = text.rangeOfComposedCharacterSequence(at: end)
            if cluster.location < end { end = cluster.location }
        }
        if end < start { end = start }
        let range = NSRange(location: start, length: end - start)
        let highlights = hits.compactMap { hit -> SearchTextRange? in
            let intersection = NSIntersectionRange(range, hit.range.nsRange)
            guard intersection.length > 0 else { return nil }
            return .init(location: intersection.location - start, length: intersection.length)
        }
        return .init(text: text.substring(with: range),
                     rangeInArticle: .init(location: start, length: end - start),
                     highlightRanges: highlights, omittedPrefix: start > 0, omittedSuffix: end < length)
    }
}
