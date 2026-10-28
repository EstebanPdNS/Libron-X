import Foundation
import Testing
@testable import LibronixCore
#if canImport(CSQLite)
import CSQLite

@Suite(.serialized) struct PersistentLibrarySearchTests {
    struct Fixture {
        let root: URL
        let resource: LibraryResource
        var cache: URL { root.appendingPathComponent("indexes") }
        init(_ texts: [String]) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-search-index-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("source.json")
            resource = .init(location: url, title: "Owned", byteCount: 0, format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
            try replace(texts.map { LibrarySearchDecodedArticle(text: $0) })
        }
        func replace(_ articles: [LibrarySearchDecodedArticle]) throws {
            try JSONEncoder().encode(articles).write(to: resource.location, options: .atomic)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
    actor Source: LibrarySearchContentProvider {
        var failReads = false
        var reads = 0
        let projectionVersion: String?
        let projectedLink: BibleReferenceSourceLink?
        init(projectionVersion: String? = nil, projectedLink: BibleReferenceSourceLink? = nil) {
            self.projectionVersion = projectionVersion; self.projectedLink = projectedLink
        }
        func blockReads() { failReads = true }
        func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
            let stamp = try LibrarySearchFileStamp.capture(resource.location)
            let articles = try JSONDecoder().decode([LibrarySearchDecodedArticle].self, from: Data(contentsOf: resource.location))
            return .init(articles: articles.indices.map { .init(sectionOrdinal: $0, title: String($0)) }, sourceStamps: [stamp], projectionVersion: projectionVersion)
        }
        func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor, prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
            try Task.checkCancellation()
            if failReads { throw LibronError.invalid("Cold reader deliberately unavailable") }
            reads += 1
            let decoded = try JSONDecoder().decode([LibrarySearchDecodedArticle].self, from: Data(contentsOf: resource.location))[article.sectionOrdinal]
            if let projectedLink { return .init(text: decoded.text, referenceLinks: [projectedLink]) }
            return decoded
        }
        func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws {
            try LibrarySearchFileStamp.verify(prepared.sourceStamps)
        }
    }
    private func search(_ provider: any LibrarySearchContentProvider, _ resource: LibraryResource,
                        _ query: String, options: TextSearchOptions = .init(), unit: LibrarySearchUnit = .article,
                        budget: LibrarySearchBudget = .init()) async throws -> LibrarySearchReport {
        try await LibrarySearchService(provider: provider).search(resources: [resource], query: SearchQueryParser.parse(query), options: options, unit: unit, budget: budget)
    }
    private func modify(_ fixture: Fixture, sql: String) throws {
        let url = fixture.cache.appendingPathComponent(PersistentLibrarySearchProvider.filename(for: fixture.resource))
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func changedProjectionInvalidatesTextOnlyCacheWithoutChangingTheOriginal() async throws {
        let fixture = try Fixture(["😀 16"]); defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.resource.location)
        let old = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        _ = try await search(old, fixture.resource, "16")
        let link = BibleReferenceSourceLink(range: .init(location: 3, length: 2), target: "=rJn3:16(RVR60)")
        let newSource = Source(projectionVersion: "checked-links-v1", projectedLink: link)
        let upgraded = PersistentLibrarySearchProvider(source: newSource, directory: fixture.cache)
        let query = try BibleReferenceQuery.parse("John3:16(RVR60)")
        let fresh = try await BibleReferenceSearchService(provider: upgraded).search(resources: [fixture.resource], query: query)
        #expect(fresh.coverageComplete && fresh.results.count == 1)
        #expect(fresh.results.first?.mention.origin == .explicitLink && fresh.results.first?.mention.label == "16")
        let upgradedMetrics = await upgraded.metrics
        #expect(upgradedMetrics.sourceReads == 1 && upgradedMetrics.cachedReads == 0)
        let blocked = Source(projectionVersion: "checked-links-v1", projectedLink: link); await blocked.blockReads()
        let reopened = PersistentLibrarySearchProvider(source: blocked, directory: fixture.cache)
        let warm = try await BibleReferenceSearchService(provider: reopened).search(resources: [fixture.resource], query: query)
        #expect(warm.coverageComplete && warm.results.map(\.mention) == fresh.results.map(\.mention))
        let warmMetrics = await reopened.metrics
        #expect(warmMetrics.sourceReads == 0 && warmMetrics.cachedReads == 1)
        #expect(try Data(contentsOf: fixture.resource.location) == original)
    }

    @Test func olderPreparedIdentitiesDecodeWithoutAssumingReferenceCompleteness() throws {
        let old = try JSONDecoder().decode(LibrarySearchPreparedResource.self, from: Data(#"{"articles":[],"sourceStamps":[],"warnings":[]}"#.utf8))
        #expect(old.projectionVersion == nil)
        let upgraded = LibrarySearchPreparedResource(articles: [], projectionVersion: "checked-links-v1")
        #expect(try JSONEncoder().encode(old) != JSONEncoder().encode(upgraded))
        #expect(try JSONDecoder().decode(LibrarySearchPreparedResource.self, from: JSONEncoder().encode(upgraded)).projectionVersion == "checked-links-v1")
    }

    @Test func compactDirectoryKeepsLargeOrdinalsAndIdentityWithoutMaterializingEntries() throws {
        let original = LibrarySearchPreparedResource(contiguousArticleCount: 837_661, titlePrefix: "Dictionary")
        try original.validateDirectory()
        let encoded = try JSONEncoder().encode(original)
        #expect(encoded.count < 1_024)
        let decoded = try JSONDecoder().decode(LibrarySearchPreparedResource.self, from: encoded)
        #expect(decoded.articleCount == 837_661 && decoded.isCompactDirectory)
        #expect(decoded.orderedArticles().prefix(2).map(\.sectionOrdinal) == [0, 1])
        #expect(decoded.article(at: 837_660)?.title == "Dictionary · 837661")
        #expect(decoded.article(at: 837_661) == nil)
        #expect(throws: (any Error).self) { try LibrarySearchPreparedResource(contiguousArticleCount: 0, titlePrefix: "Empty").validateDirectory() }
    }

    @Test func reopeningTheIndexReusesTextAndPrunesOnlyProvenNonmatches() async throws {
        let fixture = try Fixture(["faith hope", "no related term", "FAITH", "another entry"]); defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.resource.location)
        let first = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        let cold = try await search(first, fixture.resource, "faith")
        #expect(cold.coverageComplete && cold.results.map(\.sectionOrdinal) == [0, 2])
        let metrics61 = await first.metrics
        #expect(metrics61.sourceReads == 4)
        let blocked = Source(); await blocked.blockReads()
        let reopened = PersistentLibrarySearchProvider(source: blocked, directory: fixture.cache)
        let warm = try await search(reopened, fixture.resource, "faith")
        #expect(warm.results == cold.results && warm.coverageComplete)
        #expect(warm.counters.articlesRuledOutByIndex == 2 && warm.counters.articlesExamined == 2)
        #expect(warm.resourceReports[0].articlesRuledOutByIndex == 2)
        let metrics68 = await reopened.metrics
        #expect(metrics68.cachedReads == 2 && metrics68.sourceReads == 0)
        #expect(try Data(contentsOf: fixture.resource.location) == before)
    }

    @Test func interruptedPartialIndexesKeepEveryUnindexedArticleAsACandidate() async throws {
        let fixture = try Fixture(["nothing here", "faith later", "hope at end"]); defer { fixture.remove() }
        let first = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        let partial = try await search(first, fixture.resource, "faith", budget: .init(maximumArticles: 1))
        #expect(partial.truncated && !partial.coverageComplete && partial.results.isEmpty)
        let next = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        let result = try await search(next, fixture.resource, "faith")
        #expect(result.coverageComplete && result.results.map(\.sectionOrdinal) == [1])
        #expect(result.counters.articlesRuledOutByIndex == 1 && result.counters.articlesExamined == 2)
        let metrics81 = await next.metrics
        #expect(metrics81.sourceReads == 2)
    }

    @Test func indexedAndLinearResultsAgreeAcrossUnicodeBooleanAndSensitivityCases() async throws {
        let fixture = try Fixture(["faith hope", "FAITH and Hope", "faithless hopeful", "faith \"hope\"", "abc-def abc_def", "café a\u{301}rbol 😀 faith", "Kelvin ﬃ ﬁ", "before\0faith after", "faith", "hope", "faith AND hope", "3.14159265", "plain entry"])
        defer { fixture.remove() }
        let index = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        _ = try await search(index, fixture.resource, "NOT absent")
        for query in ["faith", "fai", "ai", "FAITH", "faith AND hope", "faith OR hope", "NOT faith", "NOT NOT faith", "faith AND NOT hope", "NOT faith OR hope", "\"faith hope\"", "\"abc-def\"", "\"abc_def\"", "cafe", "café", "árbol", "Kelvin", "ffi", "AND", "\"3.14\"", "faith OR café"] {
            for options in [TextSearchOptions(), .init(caseSensitive: true), .init(wholeWords: false), .init(diacriticSensitive: false, wholeWords: false)] {
                let baseline = try await search(Source(), fixture.resource, query == "AND" ? "\"AND\"" : query, options: options)
                let actual = try await search(index, fixture.resource, query == "AND" ? "\"AND\"" : query, options: options)
                #expect(actual.results == baseline.results, "Indexed result changed for \(query)")
                #expect(actual.coverageComplete == baseline.coverageComplete)
                #expect(actual.counters.articlesExamined + actual.counters.articlesRuledOutByIndex == 13)
            }
        }
        let metrics98 = await index.metrics
        #expect(metrics98.cacheFailures == 0)
    }

    @Test func sourceChangesInvalidateOldTextIncludingChangesWithTheSameLength() async throws {
        let fixture = try Fixture(["old faith", "no result"]); defer { fixture.remove() }
        let first = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        _ = try await search(first, fixture.resource, "faith")
        try fixture.replace([.init(text: "new grace"), .init(text: "no result")])
        let next = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        let result = try await search(next, fixture.resource, "grace")
        #expect(result.coverageComplete && result.results.map(\.sectionOrdinal) == [0])
        let metrics109 = await next.metrics
        #expect(metrics109.sourceReads == 2 && metrics109.cachedReads == 0)
        let absent = try await search(next, fixture.resource, "faith")
        #expect(absent.coverageComplete && absent.results.isEmpty)
    }

    @Test func sharedPageCoordinatesAndVerseAnchorsSurviveIndexSerialization() async throws {
        let fixture = try Fixture(["unused"]); defer { fixture.remove() }
        let text = "😀 prefix faith hope"
        let start = "😀 prefix ".utf16.count
        let verse = LibrarySearchBibleVerse(reference: "Ge 1:1", normalizedReference: LegacyPassageQuery.parse("Ge 1:1")!.normalizedKey, range: .init(location: start, length: "faith hope".utf16.count))
        try fixture.replace([.init(text: text, bibleVerses: [verse], searchRange: .init(location: start, length: "faith hope".utf16.count))])
        let cold = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        let article = try await search(cold, fixture.resource, "faith")
        let blocked = Source(); await blocked.blockReads()
        let warm = PersistentLibrarySearchProvider(source: blocked, directory: fixture.cache)
        let result = try await search(warm, fixture.resource, "hope", unit: .bibleVerse)
        #expect(result.coverageComplete && result.counters.versesExamined == 1)
        #expect(result.results[0].hits[0].range.location == start + 6)
        #expect(result.results[0].decodedTextSHA256 == article.results[0].decodedTextSHA256)
        #expect(result.results[0].verseRange == verse.range)
    }

    @Test func corruptRecordsFallBackToTheSourceAndTheNextSearchRebuilds() async throws {
        let fixture = try Fixture(["faith", "hope"]); defer { fixture.remove() }
        let first = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        _ = try await search(first, fixture.resource, "faith")
        try modify(fixture, sql: "UPDATE articles SET body=x'00' WHERE ordinal=0")
        let next = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        let result = try await search(next, fixture.resource, "faith")
        #expect(result.coverageComplete && result.results.map(\.sectionOrdinal) == [0])
        let metrics139 = await next.metrics
        #expect(metrics139.recoveries == 1 && metrics139.sourceReads == 1)
        let rebuilt = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        _ = try await search(rebuilt, fixture.resource, "hope")
        let metrics142 = await rebuilt.metrics
        #expect(metrics142.sourceReads == 2)
    }

    @Test func invalidDatabaseBytesAreQuarantinedWithoutTouchingSource() async throws {
        let fixture = try Fixture(["faith", "hope"]); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.cache, withIntermediateDirectories: true)
        let cache = fixture.cache.appendingPathComponent(PersistentLibrarySearchProvider.filename(for: fixture.resource))
        try Data("not sqlite".utf8).write(to: cache)
        let before = try Data(contentsOf: fixture.resource.location)
        let provider = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        let result = try await search(provider, fixture.resource, "faith")
        #expect(result.coverageComplete && result.results.count == 1)
        let metrics154 = await provider.metrics
        #expect(metrics154.recoveries == 1)
        #expect(try Data(contentsOf: fixture.resource.location) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).contains { $0.contains(".invalid-") })
    }

    @Test func unavailableCacheAndCancelledSearchPreserveLinearBehavior() async throws {
        let fixture = try Fixture(["faith"]); defer { fixture.remove() }
        let invalidFolder = fixture.root.appendingPathComponent("file-not-directory")
        try Data("owned sentinel".utf8).write(to: invalidFolder)
        let provider = PersistentLibrarySearchProvider(source: Source(), directory: invalidFolder)
        let report = try await search(provider, fixture.resource, "faith")
        #expect(report.coverageComplete && report.results.count == 1)
        let metrics166 = await provider.metrics
        #expect(metrics166.cacheFailures == 1)
        #expect(try String(contentsOf: invalidFolder, encoding: .utf8) == "owned sentinel")
        let task = Task { try await search(provider, fixture.resource, "faith") }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func missingIndexTablesRecoverAndConcurrentSearchesKeepEveryMatch() async throws {
        let fixture = try Fixture((0..<120).map { $0.isMultiple(of: 3) ? "faith hope \($0)" : "unrelated \($0)" })
        defer { fixture.remove() }
        let initial = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        _ = try await search(initial, fixture.resource, "faith")
        try modify(fixture, sql: "DROP TABLE terms")
        let repaired = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        let result = try await search(repaired, fixture.resource, "faith")
        #expect(result.coverageComplete && result.results.count == 40)
        let repairMetrics = await repaired.metrics
        #expect(repairMetrics.recoveries == 1 && repairMetrics.sourceReads == 120)
        // Independent actors/connections share one cache, as cancelled/replaced
        // searches can do in the application. Each result must remain complete.
        let a = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        let b = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
        async let first = search(a, fixture.resource, "faith")
        async let second = search(b, fixture.resource, "NOT unrelated")
        let (one, two) = try await (first, second)
        #expect(one.coverageComplete && two.coverageComplete)
        #expect(one.results.map(\.sectionOrdinal) == result.results.map(\.sectionOrdinal))
        #expect(two.results.map(\.sectionOrdinal) == result.results.map(\.sectionOrdinal))
    }

    @Test func corruptedCandidateMetadataCannotHideUnicodeMatchesOrRelocateArticles() async throws {
        for sql in ["UPDATE articles SET ascii=1 WHERE ordinal=0", "UPDATE articles SET ordinal=9 WHERE ordinal=0"] {
            let fixture = try Fixture(["café faith", "unrelated entry"]); defer { fixture.remove() }
            let first = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
            let original = try await search(first, fixture.resource, "faith")
            try modify(fixture, sql: sql)
            let repaired = PersistentLibrarySearchProvider(source: Source(), directory: fixture.cache)
            let result = try await search(repaired, fixture.resource, "faith")
            #expect(result.coverageComplete && result.results == original.results)
            let metrics = await repaired.metrics
            #expect(metrics.recoveries == 1 && metrics.sourceReads == 2)
        }
    }

}
#endif
