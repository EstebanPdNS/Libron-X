import Foundation
import Testing
@testable import LibronixCore

@Suite struct LibrarySearchServiceTests {
    private func resource(_ name: String, format: ResourceFormat = .legacyLSF,
                          support: ResourceSupport = .metadataOnly, location: URL? = nil) -> LibraryResource {
        .init(location: location ?? URL(fileURLWithPath: "/tmp/library-search-synthetic/\(name).LSF"),
              title: name, byteCount: 0, format: format, support: support, provenance: .fileName)
    }

    private func query(_ value: String = "faith") throws -> SearchQuery { try SearchQueryParser.parse(value) }

    private func verse(_ reference: String, start: Int, length: Int) -> LibrarySearchBibleVerse {
        .init(reference: reference, normalizedReference: LegacyPassageQuery.parse(reference)!.normalizedKey,
              range: .init(location: start, length: length))
    }

    @Test func verseScopeDoesNotJoinBooleanOperandsOrPhrasesAcrossReferences() async throws {
        let book = resource("verse-boundaries")
        let prefix = "heading 😀 ", first = "faith ", second = "hope ", third = "faith hope"
        let text = prefix + first + second + third
        let verses = [verse("Ge 1:1", start: prefix.utf16.count, length: first.utf16.count),
            verse("Ge 1:2", start: (prefix + first).utf16.count, length: second.utf16.count),
            verse("Ge 1:3", start: (prefix + first + second).utf16.count, length: third.utf16.count)]
        let provider = SyntheticSearchProvider(articles: [book.id: [.init(ordinal: 0, text: text, bibleVerses: verses)]])
        let service = LibrarySearchService(provider: provider)
        let articles = try await service.search(resources: [book], query: query("\"faith hope\""))
        #expect(articles.results[0].hitCount == 2)
        for expression in ["faith AND hope", "\"faith hope\""] {
            let report = try await service.search(resources: [book], query: query(expression), unit: .bibleVerse)
            #expect(report.unit == .bibleVerse && report.coverageComplete)
            #expect(report.counters.versesExamined == 3 && report.counters.matchingVerses == 1)
            #expect(report.counters.matchingArticles == 1 && report.results.count == 1)
            #expect(report.results[0].bibleReference == "ge 1:3")
            #expect(report.results[0].verseRange == verses[2].range)
            #expect(report.results[0].hits.allSatisfy { $0.range.location >= verses[2].range.location })
        }
        let heading = try await service.search(resources: [book], query: query("heading"), unit: .bibleVerse)
        #expect(heading.results.isEmpty && heading.coverageComplete)
    }

    @Test func verseOffsetsSnippetsAndWholeArticleFingerprintStayInTheOriginalUTF16Space() async throws {
        let book = resource("verse-unicode")
        let prefix = "heading 😀 ", first = "😀 faith ", second = "café faith שָׁלוֹם"
        let text = prefix + first + second, start = (prefix + first).utf16.count
        let verses = [verse("Jn 1:1", start: prefix.utf16.count, length: first.utf16.count),
                      verse("Jn 1:2", start: start, length: second.utf16.count)]
        let provider = SyntheticSearchProvider(articles: [book.id: [.init(ordinal: 4, text: text, bibleVerses: verses)]])
        let report = try await LibrarySearchService(provider: provider).search(resources: [book], query: query("café"), unit: .bibleVerse)
        let result = try #require(report.results.first)
        #expect(result.hits[0].range == .init(location: start, length: 5))
        #expect(result.decodedTextSHA256 == LibrarySearchService.textFingerprint(text))
        #expect(result.snippet.rangeInArticle.location >= start)
        #expect(result.snippet.rangeInArticle.upperBound <= text.utf16.count)
        #expect((text as NSString).substring(with: result.snippet.rangeInArticle.nsRange) == result.snippet.text)
        #expect(!result.snippet.text.contains("heading"))
        #expect(result.id == book.id + "#section=4#verse=\(start)")
    }

    @Test func verseResultBudgetsCanStopInsideOneArticleAndNegativeQueriesHaveNavigableIntervals() async throws {
        let book = resource("verse-budgets"), text = "faith faith faith"
        let verses = [verse("Ge 1:1", start: 0, length: 6), verse("Ge 1:2", start: 6, length: 6),
                      verse("Ge 1:3", start: 12, length: 5)]
        let provider = SyntheticSearchProvider(articles: [book.id: [.init(ordinal: 0, text: text, bibleVerses: verses)]])
        let service = LibrarySearchService(provider: provider)
        let partial = try await service.search(resources: [book], query: query(), unit: .bibleVerse,
                                               budget: .init(maximumResults: 1))
        #expect(partial.limitReason == .results && !partial.coverageComplete)
        #expect(partial.counters.articlesExamined == 1 && partial.counters.versesExamined == 1)
        #expect(partial.results.count == 1 && partial.resourceReports[0].status == .partial)
        let exact = try await service.search(resources: [book], query: query("NOT fear"), unit: .bibleVerse,
            budget: .init(maximumArticles: 1, maximumResults: 3))
        #expect(exact.coverageComplete && exact.counters.matchingArticles == 1 && exact.counters.matchingVerses == 3)
        #expect(Set(exact.results.map(\.id)).count == 3)
        #expect(exact.results.allSatisfy { $0.hits.isEmpty && $0.hitCount == 0 && $0.verseRange != nil })
    }

    @Test func missingVerseAnchorsAndInvalidIntervalsRemainExplicitWithoutBreakingArticleMode() async throws {
        let missing = resource("no-anchors"), broken = resource("bad-anchors")
        let provider = SyntheticSearchProvider(articles: [missing.id: [.init(ordinal: 0, text: "faith")],
            broken.id: [.init(ordinal: 0, text: "faith", bibleVerses: [verse("Ge 1:1", start: 0, length: 4),
                                                                         verse("Ge 1:2", start: 2, length: 3)])]])
        let service = LibrarySearchService(provider: provider)
        let report = try await service.search(resources: [missing, broken], query: query(), unit: .bibleVerse)
        #expect(report.results.isEmpty && !report.coverageComplete)
        #expect(report.resourceReports[0].status == .incompatible)
        #expect(report.resourceReports[0].warnings.contains { $0.contains("intervalos") })
        #expect(report.resourceReports[1].status == .partial)
        #expect(report.resourceReports[1].errors[0].code == "search-provider")
        let articles = try await service.search(resources: [missing, broken], query: query())
        #expect(articles.coverageComplete && articles.results.count == 2)
    }

    @Test func sourceBibleAnchorsKeepLabelsCollapseRepeatsAndRejectAmbiguousOrInvalidPositions() throws {
        func anchor(_ label: String, _ offset: Int, type: UInt16 = 2) -> LegacyReferenceAnchor {
            .init(reference: label, flags: 128, dataTypeCode: type, characterOffset: offset, decodedOffset: 0)
        }
        let text = "😀 faith hope"
        let valid = try BibleVerseText.intervals(text: text, anchors: [anchor("Page 1", 0), anchor("Ge 1:1", 3),
            anchor("Gen 1:1", 5), anchor("Ge 1:2", 9), anchor("Ge 1:3", 10, type: 9)])
        #expect(valid.map(\.normalizedReference) == ["ge 1:1", "ge 1:2"])
        #expect(valid.map(\.range) == [.init(location: 3, length: 6), .init(location: 9, length: 4)])
        for anchors in [[anchor("Ge 1:1", 1)], [anchor("Ge 1:1", -1)], [anchor("Ge 1:1", 99)],
                        [anchor("Ge 1:1", 3), anchor("Ge 1:2", 3)],
                        [anchor("Ge 1:1", 3), anchor("Ge 1:2", 9), anchor("Ge 1:3", 5)],
                        [anchor("Ge 1:1", 3), anchor("Ge 1:2", 9), anchor("Ge 1:1", 12)]] {
            #expect(throws: LibrarySearchError.invalidVerseDirectory) {
                try BibleVerseText.intervals(text: text, anchors: anchors)
            }
        }
    }

    @Test func defaultAdapterFindsVersesInAnOwnAnchoredLSFFixture() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".LSF")
        try SyntheticSearchLSF.file(["faith hope", "faith"], references: ["Ge 1:1", "Ge 1:2"]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try await LibrarySearchService().search(resources: [resource("anchored-fixture", location: url)],
                                                            query: query(), unit: .bibleVerse)
        #expect(report.coverageComplete && report.counters.versesExamined == 2)
        #expect(report.results.map(\.bibleReference) == ["ge 1:1", "ge 1:2"])
        #expect(report.results.allSatisfy { $0.sourceStamps.count == 1 && $0.verseRange?.location == 0 })
    }

    @Test func articleScopesAndPhysicalOrderAreStableAndDoNotJoinDifferentArticles() async throws {
        let book = resource("a")
        let provider = SyntheticSearchProvider(articles: [book.id: [
            .init(ordinal: 5, text: "faith"), .init(ordinal: 0, text: "hope"), .init(ordinal: 2, text: "faith hope")]])
        let service = LibrarySearchService(provider: provider)
        let report = try await service.search(resources: [book], query: query("faith AND hope"))
        #expect(report.coverageComplete)
        #expect(report.results.map(\.sectionOrdinal) == [2])
        #expect(report.counters.articlesTotalKnown == 3)
        #expect(report.counters.articlesExamined == 3)
        #expect(report.counters.articlesDecoded == 3)
        #expect(report.counters.occurrencesObserved == 2)
        #expect(report.results[0].id == book.id + "#section=2")
        let negative = try await service.search(resources: [book], query: query("NOT fear"))
        #expect(negative.results.map(\.sectionOrdinal) == [0, 2, 5])
        #expect(negative.results.allSatisfy { $0.hitCount == 0 && $0.hits.isEmpty })
        #expect(negative.results[0].snippet.text == "hope")
    }

    @Test func unsupportedAndInvalidResourcesAreRecordedEvenWhenNoTextCanBeSearched() async throws {
        let good = resource("good"), opaque = resource("opaque", format: .libronixOEB, support: .opaqueContainer)
        let lls = resource("lls", format: .libronixLLS, support: .opaqueContainer)
        let invalid = resource("invalid", support: .invalidFile), broken = resource("broken")
        let provider = SyntheticSearchProvider(articles: [good.id: [.init(ordinal: 0, text: "faith")]],
                                                preparationFailures: [broken.id])
        let report = try await LibrarySearchService(provider: provider).search(
            resources: [good, opaque, lls, invalid, broken], query: query())
        #expect(report.counters.resourcesTotal == 5)
        #expect(report.counters.resourcesExamined == 5)
        #expect(report.counters.resourcesCompleted == 1)
        #expect(report.counters.resourcesIncompatible == 2)
        #expect(report.counters.resourcesFailed == 2)
        #expect(report.counters.resourcesWithUnknownArticleTotal == 4)
        #expect(report.resourceReports.map(\.status) == [.complete, .incompatible, .failed, .incompatible, .failed])
        #expect(!report.coverageComplete && !report.truncated)
        let none = try await LibrarySearchService(provider: provider).search(resources: [opaque, invalid], query: query())
        #expect(none.results.isEmpty && !none.coverageComplete)
        #expect(none.counters.resourcesIncompatible == 2)
    }

    @Test func readAndEvaluationFailuresCannotBeReportedAsSuccessfulAbsence() async throws {
        let book = resource("partial")
        let provider = SyntheticSearchProvider(articles: [book.id: [
            .init(ordinal: 0, text: "faith"), .init(ordinal: 1, text: "hope"), .init(ordinal: 2, text: "faith")]],
            readFailures: [book.id: [1]])
        let report = try await LibrarySearchService(provider: provider).search(resources: [book], query: query())
        #expect(report.results.map(\.sectionOrdinal) == [0, 2])
        #expect(report.counters.articlesExamined == 3)
        #expect(report.counters.articlesDecoded == 2)
        #expect(report.counters.articlesFailed == 1)
        #expect(report.resourceReports[0].errors.first?.sectionOrdinal == 1)
        #expect(report.resourceReports[0].status == .partial)
        #expect(!report.coverageComplete)
        let evaluationProvider = SyntheticSearchProvider(articles: [book.id: [.init(ordinal: 0, text: "faith faith")]])
        let limited = try await LibrarySearchService(provider: evaluationProvider).search(
            resources: [book], query: query(), options: .init(maximumMatchAttempts: 1))
        #expect(!limited.coverageComplete)
        #expect(limited.resourceReports[0].errors.contains { $0.code == "text-evaluation" })
    }

    @Test func articleResultAndOccurrenceBudgetsDescribeWhatWasOmitted() async throws {
        let book = resource("limits"), later = resource("later"), opaque = resource("oeb", format: .libronixOEB)
        let provider = SyntheticSearchProvider(articles: [book.id: [
            .init(ordinal: 0, text: "faith faith faith"), .init(ordinal: 1, text: "faith"), .init(ordinal: 2, text: "faith")],
            later.id: [.init(ordinal: 0, text: "faith")]])
        let service = LibrarySearchService(provider: provider)
        let articles = try await service.search(resources: [book, later, opaque], query: query(),
                                               budget: .init(maximumArticles: 2))
        #expect(articles.limitReason == .articles)
        #expect(articles.counters.articlesExamined == 2)
        #expect(articles.resourceReports[1].status == .notExamined)
        #expect(articles.resourceReports[2].status == .incompatible)
        let results = try await service.search(resources: [book], query: query(), budget: .init(maximumResults: 1))
        #expect(results.limitReason == .results)
        #expect(results.results.count == 1 && results.counters.articlesExamined == 1)
        let occurrences = try await service.search(resources: [book], query: query(), budget: .init(maximumOccurrences: 2))
        #expect(occurrences.limitReason == .occurrences)
        #expect(occurrences.counters.occurrencesObserved == 3)
        #expect(occurrences.counters.occurrencesReturned == 2)
        #expect(occurrences.results[0].hitCount == 3 && occurrences.results[0].hits.count == 2)
        #expect(!occurrences.coverageComplete)
        let oneProvider = SyntheticSearchProvider(articles: [book.id: [.init(ordinal: 0, text: "faith")]])
        let exact = try await LibrarySearchService(provider: oneProvider).search(
            resources: [book], query: query(), budget: .init(maximumArticles: 1, maximumResults: 1, maximumOccurrences: 1))
        #expect(exact.coverageComplete && !exact.truncated)
    }

    @Test func durationBudgetIsCooperativeAndProgressContainsNoBookText() async throws {
        let book = resource("time")
        let provider = SyntheticSearchProvider(articles: [book.id: [.init(ordinal: 0, text: "faith"), .init(ordinal: 1, text: "faith")]],
                                                delay: .milliseconds(100))
        let recorder = SearchProgressRecorder()
        let report = try await LibrarySearchService(provider: provider).search(resources: [book], query: query(),
            budget: .init(maximumDurationSeconds: 0.03), onProgress: { await recorder.record($0) })
        #expect(report.limitReason == .duration && !report.coverageComplete)
        #expect(report.counters.articlesDecoded <= 1)
        #expect(await recorder.count() >= 2)
    }

    @Test func progressBatchesAndSourceChangesBetweenArticlesAbortTheWholeSearch() async throws {
        let book = resource("changing")
        let provider = SyntheticSearchProvider(articles: [book.id: (0..<5).map { .init(ordinal: $0, text: "faith") }])
        let recorder = SearchProgressRecorder()
        do {
            _ = try await LibrarySearchService(provider: provider).search(resources: [book], query: query(),
                budget: .init(progressBatchSize: 2), onProgress: { progress in
                    await recorder.record(progress)
                    if progress.counters.articlesExamined == 2 { await provider.change(book.id) }
                })
            Issue.record("Changed source produced a report")
        } catch let error as LegacyIndicesError { #expect(error == .sourceChanged) }
        #expect(await recorder.examined() == [0, 2])
    }

    @Test func aPreviouslyScannedSourceIsRecheckedAtTheEnd() async throws {
        let a = resource("a-final"), b = resource("b-final")
        let provider = SyntheticSearchProvider(articles: [a.id: [.init(ordinal: 0, text: "faith")], b.id: [.init(ordinal: 0, text: "faith")]])
        do {
            _ = try await LibrarySearchService(provider: provider).search(resources: [a, b], query: query(), onProgress: { progress in
                if progress.currentResourceTitle == b.title { await provider.change(a.id) }
            })
            Issue.record("Earlier source change was ignored")
        } catch let error as LegacyIndicesError { #expect(error == .sourceChanged) }
    }

    @Test func cancellationDuringAProgressCallbackReturnsNoPartialSuccessfulReport() async throws {
        let book = resource("cancel")
        let provider = SyntheticSearchProvider(articles: [book.id: (0..<4).map { .init(ordinal: $0, text: "faith") }])
        let service = LibrarySearchService(provider: provider)
        let q = try query()
        let task = Task {
            try await service.search(resources: [book], query: q, budget: .init(progressBatchSize: 1), onProgress: { progress in
                if progress.counters.articlesExamined == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await task.value; Issue.record("Cancelled search returned a report") }
        catch is CancellationError {}
    }

    @Test func snippetsAndFingerprintsPreserveTheExactDecodedRepresentation() async throws {
        let book = resource("unicode")
        let text = "😀 aa 👩‍💻 café שָׁלוֹם ending"
        let provider = SyntheticSearchProvider(articles: [book.id: [.init(ordinal: 0, text: text)]])
        let service = LibrarySearchService(provider: provider)
        for maximum in [1, 2, 3, 4, 5, 8, 13, 20] {
            let report = try await service.search(resources: [book], query: query("café"),
                budget: .init(snippetUTF16: maximum))
            let result = try #require(report.results.first)
            let snippet = result.snippet
            #expect(snippet.text.utf16.count <= maximum)
            #expect((text as NSString).substring(with: snippet.rangeInArticle.nsRange) == snippet.text)
            let range = try #require(Range(snippet.rangeInArticle.nsRange, in: text))
            #expect(range.lowerBound == text.endIndex || text.indices.contains(range.lowerBound))
            #expect(range.upperBound == text.endIndex || text.indices.contains(range.upperBound))
            #expect(result.decodedTextSHA256 == LibrarySearchService.textFingerprint(text))
            #expect(result.hits[0].range.length == 5)
        }
        #expect(LibrarySearchService.textFingerprint("café") != LibrarySearchService.textFingerprint("café"))
        let giant = "e" + String(repeating: "\u{0301}", count: 20)
        let hit = try TextSearchEngine.search(query: query("e"), in: giant, options: .init(diacriticSensitive: false)).hits
        let omitted = LibrarySearchService.snippet(giant, hits: hit, maximumUTF16: 4)
        #expect(omitted.text.isEmpty && omitted.omittedSuffix)
    }

    @Test func invalidInputsAndEmptyArticleDirectoriesStayExplicit() async throws {
        let book = resource("empty")
        let service = LibrarySearchService(provider: SyntheticSearchProvider(articles: [book.id: []]))
        let empty = try await service.search(resources: [book], query: query())
        #expect(empty.resourceReports[0].status == .failed && !empty.coverageComplete)
        do { _ = try await service.search(resources: [book, book], query: query()); Issue.record("Duplicate scope accepted") }
        catch let error as LibrarySearchError { #expect(error == .duplicateResourceID(book.id)) }
        do { _ = try await service.search(resources: [book], query: query(), budget: .init(maximumDurationSeconds: .infinity)); Issue.record("Invalid budget accepted") }
        catch let error as LibrarySearchError { #expect(error == .invalidBudget) }
        do { _ = try await service.search(resources: [book], query: query(), options: .init(maximumHits: 0)); Issue.record("Invalid evaluator options accepted") }
        catch let error as TextSearchError { #expect(error == .invalidLimits) }
    }

    @Test func defaultAdapterReadsOwnLSFFixtureAndDetectsFileMutation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".LSF")
        try SyntheticSearchLSF.file(["faith hope", "faith"]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let book = resource("real-adapter-fixture", location: url)
        let service = LibrarySearchService()
        let report = try await service.search(resources: [book], query: query())
        #expect(report.coverageComplete && report.results.count == 2)
        #expect(report.results[0].sourceStamps.count == 1)
        #expect(report.resourceReports[0].warnings.contains { $0.contains("LIX") })
        do {
            _ = try await service.search(resources: [book], query: query(), budget: .init(progressBatchSize: 1), onProgress: { progress in
                if progress.counters.articlesExamined == 1 {
                    if let handle = try? FileHandle(forWritingTo: url) {
                        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data([0])); try? handle.close()
                    }
                }
            })
            Issue.record("Mutation of actual fixture was ignored")
        } catch let error as LegacyIndicesError { #expect(error == .sourceChanged) }
    }
}

private struct SyntheticSearchArticle: Sendable {
    let ordinal: Int
    let text: String
    let bibleVerses: [LibrarySearchBibleVerse]
    init(ordinal: Int, text: String, bibleVerses: [LibrarySearchBibleVerse] = []) {
        self.ordinal = ordinal; self.text = text; self.bibleVerses = bibleVerses
    }
}

private enum SyntheticSearchFailure: Error, Sendable { case preparation, read }

private actor SyntheticSearchProvider: LibrarySearchContentProvider {
    let articles: [String: [SyntheticSearchArticle]]
    let preparationFailures: Set<String>
    let readFailures: [String: Set<Int>]
    let delay: Duration
    var changed = Set<String>()
    init(articles: [String: [SyntheticSearchArticle]], preparationFailures: Set<String> = [],
         readFailures: [String: Set<Int>] = [:], delay: Duration = .zero) {
        self.articles = articles; self.preparationFailures = preparationFailures
        self.readFailures = readFailures; self.delay = delay
    }
    func change(_ id: String) { changed.insert(id) }
    func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
        if preparationFailures.contains(resource.id) { throw SyntheticSearchFailure.preparation }
        return .init(articles: articles[resource.id, default: []].map { .init(sectionOrdinal: $0.ordinal, title: "Synthetic \($0.ordinal)") })
    }
    func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor,
              prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
        if delay > .zero { try await Task.sleep(for: delay) }
        if readFailures[resource.id, default: []].contains(article.sectionOrdinal) { throw SyntheticSearchFailure.read }
        guard let entry = articles[resource.id]?.first(where: { $0.ordinal == article.sectionOrdinal }) else { throw SyntheticSearchFailure.read }
        return .init(text: entry.text, bibleVerses: entry.bibleVerses)
    }
    func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws {
        try Task.checkCancellation()
        if changed.contains(resource.id) { throw LegacyIndicesError.sourceChanged }
    }
}

private actor SearchProgressRecorder {
    var values: [LibrarySearchProgress] = []
    func record(_ progress: LibrarySearchProgress) { values.append(progress) }
    func count() -> Int { values.count }
    func examined() -> [Int] { values.map { $0.counters.articlesExamined } }
}

/// Minimal own uncompressed fixture, with two public-format Latin text runs.
private enum SyntheticSearchLSF {
    static func file(_ texts: [String], references: [String] = []) -> Data {
        func put16(_ value: UInt16, in data: inout Data, at index: Int) {
            data[index] = UInt8(value & 0xff); data[index + 1] = UInt8(value >> 8)
        }
        func put32(_ value: UInt32, in data: inout Data, at index: Int) {
            for shift in 0..<4 { data[index + shift] = UInt8((value >> UInt32(shift * 8)) & 0xff) }
        }
        var tart = Data()
        for (ordinal, text) in texts.enumerated() {
            let bytes = Data(text.utf8)
            var body = Data(repeating: 0, count: 36)
            put16(17, in: &body, at: 4); put32(1, in: &body, at: 6)
            put16(1, in: &body, at: 10); put16(1, in: &body, at: 12)
            put32(UInt32(bytes.count), in: &body, at: 16)
            put16(1, in: &body, at: 20); put16(1, in: &body, at: 22); put16(1, in: &body, at: 24)
            put32(10_000, in: &body, at: 26); put32(UInt32(bytes.count + 1), in: &body, at: 32)
            if references.indices.contains(ordinal) {
                let reference = Data(references[ordinal].utf8)
                var anchor = Data(repeating: 0, count: 8)
                put16(0x51, in: &anchor, at: 0); put16(128, in: &anchor, at: 2)
                put16(2, in: &anchor, at: 4); put16(UInt16(reference.count), in: &anchor, at: 6)
                anchor.append(reference); body.append(anchor); put16(2, in: &body, at: 24)
            }
            var run = Data(repeating: 0, count: 11)
            put16(17, in: &run, at: 0); put16(UInt16(bytes.count), in: &run, at: 6); put16(1033, in: &run, at: 8)
            body.append(run); body.append(bytes); body.append(Data([0, 0])); put32(UInt32(body.count), in: &body, at: 0)
            var header = Data(repeating: 0, count: 6); put32(UInt32(body.count), in: &header, at: 2)
            tart.append(header); tart.append(body)
        }
        var data = Data(repeating: 0, count: 88)
        data.replaceSubrange(0..<4, with: Data("LSFF".utf8)); data.replaceSubrange(8..<12, with: Data("GTTL".utf8))
        data.replaceSubrange(36..<40, with: Data("pcr ".utf8)); put32(36, in: &data, at: 40)
        data.replaceSubrange(44..<48, with: Data("LSFF".utf8)); data.replaceSubrange(48..<52, with: Data("GTTL".utf8))
        data.replaceSubrange(62..<66, with: Data("tart".utf8)); put32(UInt32(tart.count), in: &data, at: 70); put32(88, in: &data, at: 74)
        data.replaceSubrange(80..<84, with: Data("tart".utf8)); put32(UInt32(tart.count), in: &data, at: 84)
        data.append(tart); put32(UInt32(data.count - 8), in: &data, at: 4)
        return data
    }
}
