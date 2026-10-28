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

    /// Preserve the original single-progress-callback API, including trailing closures.
    public func search(resources: [LibraryResource], query: SearchQuery,
                       options: TextSearchOptions = TextSearchOptions(), unit: LibrarySearchUnit = .article,
                       bibleRange: BibleSearchRange? = nil, budget: LibrarySearchBudget = LibrarySearchBudget(),
                       onProgress: (@Sendable (LibrarySearchProgress) async -> Void)? = nil) async throws -> LibrarySearchReport {
        try await search(resources: resources, query: query, options: options, unit: unit, bibleRange: bibleRange,
                         budget: budget, control: nil, onSnapshot: nil, onProgress: onProgress)
    }

    public func search(resources: [LibraryResource], query: SearchQuery,
                       options: TextSearchOptions = TextSearchOptions(),
                       unit: LibrarySearchUnit = .article,
                       bibleRange: BibleSearchRange? = nil,
                       budget: LibrarySearchBudget = LibrarySearchBudget(),
                       control: LibrarySearchControl?,
                       onSnapshot: (@Sendable (LibrarySearchReport) async -> Void)? = nil,
                       onProgress: (@Sendable (LibrarySearchProgress) async -> Void)? = nil) async throws -> LibrarySearchReport {
        let execution = LibrarySearchExecution(provider: provider, resources: resources, query: query, options: options,
            unit: unit, bibleRange: bibleRange, budget: budget, control: control, onSnapshot: onSnapshot, onProgress: onProgress)
        return try await execution.run()
    }

    public static func textFingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func snippet(_ source: String, hits: [TextSearchHit], maximumUTF16: Int,
                        within interval: SearchTextRange? = nil) -> LibrarySearchSnippet {
        LibrarySearchExecution.snippet(source, hits: hits, maximumUTF16: maximumUTF16, within: interval)
    }
}

/// Each request has one actor-owned accumulator and one suspended scan stack.
/// Separate requests can share a provider without sharing their run state.
private actor LibrarySearchExecution {
    let provider: any LibrarySearchContentProvider
    let resources: [LibraryResource]
    let query: SearchQuery
    let options: TextSearchOptions
    let unit: LibrarySearchUnit
    let bibleRange: BibleSearchRange?
    let budget: LibrarySearchBudget
    let control: LibrarySearchControl?
    let onSnapshot: (@Sendable (LibrarySearchReport) async -> Void)?
    let onProgress: (@Sendable (LibrarySearchProgress) async -> Void)?
    let clock = ContinuousClock()
    let start: ContinuousClock.Instant
    var pausedSeconds = 0.0
    var contextRemaining: Int
    var counters = LibrarySearchCounters()
    var resourceReports: [LibrarySearchResourceReport]
    var results: [LibrarySearchResult] = []
    var limit: LibrarySearchLimit?
    var preparedSources: [(LibraryResource, LibrarySearchPreparedResource)] = []
    init(provider: any LibrarySearchContentProvider, resources: [LibraryResource], query: SearchQuery,
         options: TextSearchOptions, unit: LibrarySearchUnit, bibleRange: BibleSearchRange?, budget: LibrarySearchBudget,
         control: LibrarySearchControl?, onSnapshot: (@Sendable (LibrarySearchReport) async -> Void)?,
         onProgress: (@Sendable (LibrarySearchProgress) async -> Void)?) {
        self.provider = provider; self.resources = resources; self.query = query; self.options = options
        self.unit = unit; self.bibleRange = bibleRange; self.budget = budget; self.control = control
        self.onSnapshot = onSnapshot; self.onProgress = onProgress; self.start = clock.now
        contextRemaining = budget.maximumContextUTF16; resourceReports = resources.map(LibrarySearchResourceReport.init)
        counters.resourcesTotal = resources.count; counters.resourcesWithUnknownArticleTotal = resources.count
    }
    private func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    private func elapsed() -> Double { max(0, seconds(start.duration(to: clock.now)) - pausedSeconds) }
    private func makeReport(state: LibrarySearchRunState, complete: Bool = false) -> LibrarySearchReport {
        var report: LibrarySearchReport = .init(bibleRange: bibleRange, unit: unit, results: results, resourceReports: resourceReports, counters: counters,
        limitReason: limit, elapsedSeconds: elapsed(), coverageComplete: complete,
        scopeDescription: unit == .article
            ? "Búsqueda lineal por artículo, sobre el texto del lector compatible. Las páginas HTML compartidas se evalúan por artículo. Los rangos UTF-16 y el hash pertenecen al texto completo del lector; no son offsets de índices legados ni búsqueda de lemas/Strong."
            : "Búsqueda lineal dentro de intervalos bíblicos verificados por el lector compatible, hasta la siguiente referencia distinta o fin del artículo. Excluye prefijos sin referencia y no une versículos entre artículos. Los rangos UTF-16 y el hash corresponden al artículo completo. Índices, límites RPOS y equivalencia general con Libronix continúan pendientes.")
        report.runState = state
        return report
    }
    private func publish(_ state: LibrarySearchRunState = .running) async {
        if let onSnapshot { await onSnapshot(makeReport(state: state)) }
    }
    private func checkpoint() async throws {
        try Task.checkCancellation()
        guard let control else { return }
        if await control.state == .cancelled { throw CancellationError() }
        var suspended = false
        while await control.state == .paused {
            suspended = true
            await publish(.paused)
            let began = clock.now
            do { try await control.waitUntilRunning() }
            catch { pausedSeconds += seconds(began.duration(to: clock.now)); throw error }
            pausedSeconds += seconds(began.duration(to: clock.now))
        }
        try Task.checkCancellation()
        if await control.state == .cancelled { throw CancellationError() }
        if suspended {
            do {
                for (resource, prepared) in preparedSources { try await provider.verifyUnchanged(resource, prepared: prepared) }
            } catch is CancellationError { throw CancellationError() }
            catch { throw LibrarySearchError.resumeSourceChanged }
            await publish()
        }
    }

    private func budgetLimit(includeArticles: Bool = true) -> LibrarySearchLimit? {
        if elapsed() >= budget.maximumDurationSeconds { return .duration }
        if includeArticles && counters.articlesExamined >= budget.maximumArticles { return .articles }
        if results.count >= budget.maximumResults { return .results }
        if counters.occurrencesReturned >= budget.maximumOccurrences { return .occurrences }
        return nil
    }
    func run() async throws -> LibrarySearchReport {
        try validate(budget)
        guard bibleRange == nil || unit == .bibleVerse else { throw BibleSearchRangeError.requiresVerseMode }
        try Task.checkCancellation()
        // Validate evaluator options before classifying any source as a failed read.
        _ = try TextSearchEngine.search(query: query, in: "", options: options, verses: query.expression.requiresVerseContext ? [] : nil,
            fields: .init(regions: Dictionary(uniqueKeysWithValues: query.expression.requiredFields.map { ($0, []) })))
        let requiresBibleDirectory = query.expression.requiresVerseContext || query.expression.requiredFields.contains(.bibleText)
        var ids = Set<String>()
        for resource in resources {
            guard ids.insert(resource.id).inserted else { throw LibrarySearchError.duplicateResourceID(resource.id) }
        }

        do {
            // Opaque/invalid resources remain visible even when a later scan hits a budget.
            for index in resources.indices {
                let resource = resources[index]
                try await checkpoint()
                let supported = await provider.supports(resource)
                try Task.checkCancellation()
                if !supported || resource.support == .invalidFile {
                    resourceReports[index].status = .incompatible
                    resourceReports[index].warnings = [resource.support == .invalidFile
                        ? "El recurso fue importado como archivo inválido; no se buscó su contenido."
                        : "El lector de contenido de \(resource.format.displayName) aún no está implementado; no se buscó este recurso."]
                    counters.resourcesExamined += 1
                    counters.resourcesIncompatible += 1
                }
            }



            try await emitProgress(counters: counters, title: nil, elapsedSeconds: elapsed(), onProgress: onProgress)
            await publish()

            resourceLoop: for index in resources.indices {
                try await checkpoint()
                try Task.checkCancellation()
                if resourceReports[index].status == .incompatible { continue }
                if let reached = budgetLimit() { limit = reached; break }
                let resource = resources[index]
                counters.resourcesExamined += 1
                var hasVerseIntervals = false
                let rangePredicate = bibleRange?.bind(to: resource)
                let prepared: LibrarySearchPreparedResource
                do {
                    prepared = try await provider.prepare(resource)
                    try prepared.validateDirectory()
                    try await provider.verifyUnchanged(resource, prepared: prepared)
                } catch {
                    try propagateCritical(error)
                    resourceReports[index].status = .failed
                    resourceReports[index].errors.append(errorRecord(error, ordinal: nil))
                    counters.resourcesFailed += 1
                    try await emitProgress(counters: counters, title: resource.title, elapsedSeconds: elapsed(), onProgress: onProgress)
                    await publish()
                    continue
                }
                preparedSources.append((resource, prepared))
                counters.resourcesPrepared += 1
                counters.resourcesWithUnknownArticleTotal -= 1
                counters.articlesTotalKnown += prepared.articleCount
                resourceReports[index].totalArticles = prepared.articleCount
                resourceReports[index].warnings = prepared.warnings
                resourceReports[index].status = .partial
                if let available = prepared.availableFields {
                    let unsupported = query.expression.requiredFields.subtracting(available).sorted { $0.rawValue < $1.rawValue }
                    if !unsupported.isEmpty {
                        resourceReports[index].status = .incompatible
                        resourceReports[index].errors = unsupported.map { errorRecord(TextSearchError.unsupportedField($0), ordinal: nil) }
                        counters.resourcesIncompatible += 1
                        try await provider.verifyUnchanged(resource, prepared: prepared)
                        try await emitProgress(counters: counters, title: resource.title, elapsedSeconds: elapsed(), onProgress: onProgress)
                        await publish()
                        continue
                    }
                }
                let articles: AnySequence<LibrarySearchArticleDescriptor>
                do {
                    let ordered = prepared.orderedArticles()
                    if let candidates = try await provider.candidates(resource, prepared: prepared, query: query, options: options, unit: unit) {
                        let valid = prepared.isCompactDirectory
                            ? candidates.allSatisfy { (0..<prepared.articleCount).contains($0) }
                            : candidates.isSubset(of: Set(ordered.map(\.sectionOrdinal)))
                        guard valid else { throw LibrarySearchError.invalidArticleDirectory }
                        articles = AnySequence(ordered.lazy.filter { candidates.contains($0.sectionOrdinal) })
                        let excluded = prepared.articleCount - candidates.count
                        counters.articlesRuledOutByIndex += excluded
                        resourceReports[index].articlesRuledOutByIndex = excluded
                    } else { articles = ordered }
                    try await provider.verifyUnchanged(resource, prepared: prepared)
                } catch {
                    try propagateCritical(error)
                    resourceReports[index].status = .failed
                    resourceReports[index].errors.append(errorRecord(error, ordinal: nil))
                    counters.resourcesFailed += 1
                    continue
                }
                if elapsed() >= budget.maximumDurationSeconds { limit = .duration; break resourceLoop }
                for article in articles {
                    try await checkpoint()
                    try Task.checkCancellation()
                    if let reached = budgetLimit() { limit = reached; break resourceLoop }
                    counters.articlesExamined += 1
                    resourceReports[index].articlesExamined += 1
                    do {
                        try await provider.verifyUnchanged(resource, prepared: prepared)
                        let content = try await provider.read(resource, article: article, prepared: prepared)
                        try await provider.verifyUnchanged(resource, prepared: prepared)
                        if let range = content.searchRange {
                            let source = content.text as NSString
                            guard range.location >= 0, range.length >= 0, range.location <= source.length,
                                  range.length <= source.length - range.location,
                                  Range(range.nsRange, in: content.text) != nil,
                                  (range.location == source.length || source.rangeOfComposedCharacterSequence(at: range.location).location == range.location),
                                  (range.upperBound == source.length || source.rangeOfComposedCharacterSequence(at: range.upperBound).location == range.upperBound) else {
                                throw LibrarySearchError.invalidArticleDirectory
                            }
                        }
                        counters.articlesDecoded += 1
                        resourceReports[index].articlesDecoded += 1
                        if elapsed() >= budget.maximumDurationSeconds { limit = .duration; break resourceLoop }
                        let verses: [LibrarySearchBibleVerse]
                        if unit == .bibleVerse || requiresBibleDirectory {
                            let observed = content.referenceAnchors.isEmpty ? content.bibleVerses
                                : try BibleVerseText.intervals(text: content.text, anchors: content.referenceAnchors)
                            try BibleVerseText.validate(observed, in: content.text)
                            let logical = try observed.filter { verse in
                                guard let extent = content.searchRange else { return true }
                                let intersection = NSIntersectionRange(extent.nsRange, verse.range.nsRange)
                                guard intersection.length > 0 else { return false }
                                guard intersection == verse.range.nsRange else { throw LibrarySearchError.invalidVerseDirectory }
                                return true
                            }
                            hasVerseIntervals = hasVerseIntervals || !logical.isEmpty
                            if let rangePredicate {
                                verses = try logical.filter { verse in
                                    try Task.checkCancellation()
                                    let included = try rangePredicate.contains(verse)
                                    if !included {
                                        counters.versesExcludedByRange += 1
                                        resourceReports[index].versesExcludedByRange += 1
                                    }
                                    return included
                                }
                            } else { verses = logical }
                        } else { verses = [] }
                        if unit == .article, requiresBibleDirectory, verses.isEmpty { throw TextSearchError.verseContextRequired }
                        let intervals: [LibrarySearchBibleVerse?] = unit == .article ? [nil] : verses.map { Optional($0) }
                        var articleMatched = false
                        var fingerprint: String?
                        for verse in intervals {
                            try await checkpoint()
                            try Task.checkCancellation()
                            if let reached = budgetLimit(includeArticles: false) { limit = reached; break resourceLoop }
                            if verse != nil {
                                counters.versesExamined += 1
                                resourceReports[index].versesExamined += 1
                            }
                            let scopeRange = verse?.range ?? content.searchRange
                            let evaluationText = scopeRange.map { (content.text as NSString).substring(with: $0.nsRange) } ?? content.text
                            let verseContext: [LibrarySearchBibleVerse]?
                            if query.expression.requiresVerseContext {
                                let origin = scopeRange?.location ?? 0
                                verseContext = (verse.map { [$0] } ?? verses).map { source in
                                    .init(reference: source.reference, normalizedReference: source.normalizedReference,
                                          range: .init(location: source.range.location - origin, length: source.range.length))
                                }
                            } else { verseContext = nil }
                            let fields: SearchFieldDirectory?
                            if !query.expression.requiredFields.isEmpty {
                                var declared = content.fieldDirectory
                                if query.expression.requiredFields.contains(.bibleText) {
                                    var regions = declared?.regions ?? [:]; if regions[.bibleText] == nil { regions[.bibleText] = verses.map(\.range) }
                                    var units = declared?.witnessRegions ?? [:]
                                    if units[.bibleText] == nil, let first = verses.first, let last = verses.last {
                                        units[.bibleText] = [.init(location: first.range.location, length: last.range.upperBound - first.range.location)]
                                    }
                                    declared = .init(regions: regions, externalValues: declared?.externalValues, witnessRegions: units)
                                }
                                fields = try scopeRange.map { try declared?.clipped(to: $0, in: content.text) } ?? declared
                            } else { fields = nil }
                            try TextSearchEngine.validateLexicalBreaks(content.lexicalBreaks, in: content.text)
                            let lexical = content.lexicalBreaks?.compactMap { position -> Int? in
                                let start = scopeRange?.location ?? 0, end = scopeRange?.upperBound ?? content.text.utf16.count
                                return position > start && position < end ? position - start : nil
                            }
                            let match = try TextSearchEngine.search(query: query, in: evaluationText, options: options, verses: verseContext, fields: fields, lexicalBreaks: lexical)
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
                                    TextSearchHit(range: .init(location: hit.range.location + (scopeRange?.location ?? 0),
                                        length: hit.range.length), operands: hit.operands)
                                }
                                let externalRetained = Array(match.externalHits.prefix(max(0, remaining - retained.count)))
                                let retainedCount = retained.count + externalRetained.count
                                var contexts: [LibrarySearchOccurrenceContext] = []
                                let contextSource = evaluationText as NSString, origin = scopeRange?.location ?? 0
                                for hit in retained {
                                    if contextRemaining == 0 { break }
                                    try Task.checkCancellation()
                                    if elapsed() >= budget.maximumDurationSeconds { limit = .duration; break resourceLoop }
                                    let local = TextSearchHit(range: .init(location: hit.range.location - origin, length: hit.range.length), operands: hit.operands)
                                    let snippet = Self.snippetText(contextSource, hits: [local], maximumUTF16: min(budget.snippetUTF16, contextRemaining))
                                    guard !snippet.highlightRanges.isEmpty else { continue }
                                    contextRemaining -= snippet.text.utf16.count
                                    contexts.append(.init(range: hit.range, snippet: .init(text: snippet.text,
                                        rangeInArticle: .init(location: origin + snippet.rangeInArticle.location, length: snippet.rangeInArticle.length),
                                        highlightRanges: snippet.highlightRanges, omittedPrefix: snippet.omittedPrefix, omittedSuffix: snippet.omittedSuffix)))
                                }
                                if fingerprint == nil { fingerprint = LibrarySearchService.textFingerprint(content.text) }
                                results.append(.init(resourceID: resource.id, resourceTitle: resource.title,
                                    sectionOrdinal: article.sectionOrdinal, articleTitle: verse?.reference ?? article.title,
                                    hitCount: match.hitCount, hits: retained,
                                    snippet: Self.snippet(content.text, hits: retained, maximumUTF16: budget.snippetUTF16, within: scopeRange),
                                    decodedTextSHA256: fingerprint!, sourceStamps: prepared.sourceStamps,
                                    presentationWarnings: content.warnings,
                                    bibleReference: verse?.normalizedReference, verseRange: verse?.range, externalHits: externalRetained, contexts: contexts))
                                counters.resultsReturned += 1
                                counters.occurrencesReturned += retainedCount
                                resourceReports[index].resultsReturned += 1
                                if results.count.isMultiple(of: budget.progressBatchSize) { await publish() }
                                if retainedCount < match.hitCount { limit = .occurrences; break resourceLoop }
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
                        await publish()
                        try await provider.verifyUnchanged(resource, prepared: prepared)
                    }
                }
                if resourceReports[index].articlesExamined == prepared.articleCount - resourceReports[index].articlesRuledOutByIndex {
                    resourceReports[index].status = resourceReports[index].articlesFailed == 0 ? .complete : .partial
                    if (unit == .bibleVerse || requiresBibleDirectory) && !hasVerseIntervals && resourceReports[index].articlesFailed == 0 {
                        resourceReports[index].status = .incompatible
                        resourceReports[index].warnings.append("El contenido leído no contiene intervalos de versículos compatibles; no permite afirmar ausencia de coincidencias bíblicas.")
                        counters.resourcesIncompatible += 1
                    }
                    if resourceReports[index].status == .complete { counters.resourcesCompleted += 1 }
                }
                try await emitProgress(counters: counters, title: resource.title, elapsedSeconds: elapsed(), onProgress: onProgress)
                await publish()
                try await provider.verifyUnchanged(resource, prepared: prepared)
            }
            counters.resourcesWithUnknownArticleTotal = resourceReports.filter { $0.totalArticles == nil }.count
            try await emitProgress(counters: counters, title: nil, elapsedSeconds: elapsed(), onProgress: onProgress)
            await publish()
            // Also catch a source changing after its own last article while another
            // book is being scanned or the progress callback is running.
            for (resource, prepared) in preparedSources {
                try await provider.verifyUnchanged(resource, prepared: prepared)
            }
            try await checkpoint()
            let complete = limit == nil && counters.resourcesCompleted == counters.resourcesTotal
                && counters.articlesFailed == 0
            let report = makeReport(state: .finished, complete: complete)
            if let onSnapshot { await onSnapshot(report) }
            return report
        } catch {
            await publish(error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }

    private func emitProgress(counters: LibrarySearchCounters, title: String?, elapsedSeconds: Double,
                              onProgress: (@Sendable (LibrarySearchProgress) async -> Void)?) async throws {
        try Task.checkCancellation()
        let snapshot = LibrarySearchProgress(counters: counters, currentResourceTitle: title, elapsedSeconds: elapsedSeconds)
        if let onProgress { await onProgress(snapshot) }
        try Task.checkCancellation()
    }

    private func validate(_ budget: LibrarySearchBudget) throws { try budget.validate() }

    private func propagateCritical(_ error: any Error) throws {
        if error is CancellationError { throw CancellationError() }
        if let error = error as? LibrarySearchError, error == .resumeSourceChanged { throw error }
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
        return snippetText(source as NSString, hits: hits, maximumUTF16: maximumUTF16)
    }
    private static func snippetText(_ text: NSString, hits: [TextSearchHit], maximumUTF16: Int) -> LibrarySearchSnippet {
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
