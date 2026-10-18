import Foundation
import Testing
@testable import LibronixCore

private actor ReferenceFixtureSource: LibrarySearchContentProvider {
    let articles: [LibrarySearchDecodedArticle]
    let failed: Set<Int>
    let delay: Duration
    var changed = false
    var candidateCalls = 0
    init(_ articles: [LibrarySearchDecodedArticle], failed: Set<Int> = [], delay: Duration = .zero) {
        self.articles = articles;self.failed = failed;self.delay = delay
    }
    func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
        .init(articles:articles.indices.map { .init(sectionOrdinal:$0,title:"Owned article \($0)") })
    }
    func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor, prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
        if delay != .zero { try await Task.sleep(for:delay) }
        if failed.contains(article.sectionOrdinal) { throw LibrarySearchError.invalidArticleDirectory }
        return articles[article.sectionOrdinal]
    }
    func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws {
        if changed { throw LegacyIndicesError.sourceChanged }
        try Task.checkCancellation()
    }
    func candidates(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource, query: SearchQuery, options: TextSearchOptions, unit: LibrarySearchUnit) async throws -> Set<Int>? {
        candidateCalls += 1;return [] // A literal index cannot exclude normalized aliases.
    }
    func invalidate() { changed = true }
}
private actor ReferenceProgressSamples {
    var fields: [Int] = []
    func append(_ count: Int) { fields.append(count) }
}
struct BibleReferenceSearchTests {
    private func resource(_ name: String = "Owned", format: ResourceFormat = .legacyLSF) -> LibraryResource {
        .init(location:URL(fileURLWithPath:"/owned/\(name).bin"),title:name,byteCount:0,format:format,support:.metadataOnly,provenance:.fileName)
    }
    private func query(_ value: String) throws -> BibleReferenceQuery { try .parse(value) }
    @Test func normalizedAliasesProduceDistinctNavigableSourceRangesWithoutLiteralIndexExclusions() async throws {
        let text = "😀 John 3:16 · Juan3:16(RVR60) · Jn3:18"
        let source = ReferenceFixtureSource([.init(text:text)])
        let report = try await BibleReferenceSearchService(provider:source).search(resources:[resource()],query:query("Jn3:16"))
        try #require(report.coverageComplete && report.results.count == 2)
        #expect(Set(report.results.map(\.id)).count == 2)
        #expect(report.counters.articlesExamined == 1 && report.counters.occurrencesObserved == 2)
        #expect(await source.candidateCalls == 0)
        for match in report.results {
            let target = try #require(match.resourceDestination)
            #expect(target.decodedTextSHA256 == LibrarySearchService.textFingerprint(text))
            #expect(target.hits[0].range == match.mention.range && target.hitCount == 1)
            #expect((text as NSString).substring(with:target.hits[0].range.nsRange) == match.mention.label)
            #expect(match.personalDestination == nil && target.sectionOrdinal == 0)
        }
        let edition = try await BibleReferenceSearchService(provider:source).search(resources:[resource()],query:query("John3:16(RVR60)"))
        #expect(edition.results.count == 1 && edition.results[0].mention.citation.edition == "rvr60")
    }
    @Test func typedLinksAndLogicalArticleScopesKeepAuthoritativeTargetsAndSharedPageCoordinates() async throws {
        let text = "Jn3:16 | 😀 18 | John3:16"
        let label = (text as NSString).range(of:"18"), last = (text as NSString).range(of:"John3:16")
        let source = ReferenceFixtureSource([.init(text:text,searchRange:.init(location:label.location,length:NSMaxRange(last)-label.location),
            referenceLinks:[.init(range:.init(location:label.location,length:label.length),target:"=rJn3:16(ESV)")])])
        let report = try await BibleReferenceSearchService(provider:source).search(resources:[resource()],query:query("Jn3:16"))
        try #require(report.results.count == 2 && report.coverageComplete)
        #expect(report.results[0].mention.origin == .explicitLink && report.results[0].mention.range.location == label.location)
        #expect(report.results.allSatisfy { $0.mention.range.location >= label.location && $0.resourceDestination?.decodedTextSHA256 == LibrarySearchService.textFingerprint(text) })
        #expect(report.results.allSatisfy { !$0.snippet.text.hasPrefix("Jn3:16") })
    }
    @Test func personalFieldsStaySeparateAndRetainDocumentEntryAndTextFingerprint() async throws {
        let id = UUID(), note = UUID(), verse = UUID()
        let fields: [BibleReferencePersonalField] = [.init(kind:.documentTitle,text:"John"),.init(entryID:note,kind:.noteTitle,text:"3:16"),
            .init(entryID:note,kind:.noteBody,text:"😀 John3:16"),.init(entryID:note,kind:.noteAnchor,text:"John3:18(RVR60)"),
            .init(entryID:verse,kind:.verseEntry,text:"bible+rvr60.64.3.16")]
        let doc = BibleReferencePersonalSource(documentID:id,title:"Personal",fields:fields)
        let source = ReferenceFixtureSource([])
        let report = try await BibleReferenceSearchService(provider:source).search(resources:[],documents:[doc],query:query("Jn3:16"))
        try #require(report.coverageComplete && report.results.count == 2 && report.personalFieldsExamined == 5)
        #expect(report.documents.first?.complete == true && report.results.allSatisfy { $0.resourceDestination == nil })
        let destinations = report.results.compactMap(\.personalDestination)
        #expect(destinations.map(\.documentID) == [id,id] && destinations.map(\.entryID) == [note,verse])
        #expect(destinations[0].textSHA256 == LibrarySearchService.textFingerprint("😀 John3:16"))
        #expect(destinations.map(\.field) == [.noteBody,.verseEntry])
        let qualified = try await BibleReferenceSearchService(provider:source).search(resources:[],documents:[doc],query:query("Jn3:16(RVR60)"))
        #expect(qualified.results.count == 1 && qualified.results[0].personalDestination?.entryID == verse)
    }
    @Test func invisiblePersonalLinkChangesInvalidateProjectionIdentityEvenWithUnchangedText() async throws {
        let entry = UUID(), text = "visible label"
        let first = BibleReferencePersonalField(entryID:entry,kind:.noteBody,text:text,links:[.init(range:.init(location:0,length:text.utf16.count),target:"=rJn3:16")])
        let changed = BibleReferencePersonalField(entryID:entry,kind:.noteBody,text:text,links:[.init(range:.init(location:0,length:text.utf16.count),target:"=rRo8:1")])
        #expect(LibrarySearchService.textFingerprint(first.text) == LibrarySearchService.textFingerprint(changed.text))
        #expect(try first.projectionFingerprint() != changed.projectionFingerprint())
        let report = try await BibleReferenceSearchService(provider:ReferenceFixtureSource([])).search(resources:[],documents:[.init(documentID:UUID(),title:"Notes",fields:[first])],query:query("Jn3:16"))
        let target = try #require(report.results.first?.personalDestination)
        #expect(target.projectionSHA256 == (try first.projectionFingerprint()))
        #expect(target.projectionSHA256 != (try changed.projectionFingerprint()))
    }
    @Test func oldCachedArticleRecordsDecodeWithoutInventingExplicitLinks() throws {
        let old = Data(#"{"text":"Jn3:16","warnings":[],"bibleVerses":[],"referenceAnchors":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(LibrarySearchDecodedArticle.self,from:old)
        #expect(decoded.referenceLinks == nil && decoded.text == "Jn3:16")
        let current = LibrarySearchDecodedArticle(text:"label",referenceLinks:[.init(range:.init(location:0,length:5),target:"=rJn3:16")])
        let roundTrip = try JSONDecoder().decode(LibrarySearchDecodedArticle.self,from:JSONEncoder().encode(current))
        #expect(roundTrip.referenceLinks == current.referenceLinks)
    }
    @Test func personalProgressEmitsBoundedBatchesIndependentlyOfBookCounters() async throws {
        let fields = (0..<9).map { _ in BibleReferencePersonalField(entryID:UUID(),kind:.noteBody,text:"No citation") }
        let samples = ReferenceProgressSamples()
        let report = try await BibleReferenceSearchService(provider:ReferenceFixtureSource([])).search(resources:[],
            documents:[.init(documentID:UUID(),title:"Notes",fields:fields)],query:query("Jn3:16"),budget:.init(progressBatchSize:3),
            onProgress:{ await samples.append($0.personalFieldsExamined) })
        let values = await samples.fields
        #expect(values.contains(3) && values.contains(6) && values.last == 9)
        #expect(report.personalFieldsExamined == 9 && report.counters.articlesExamined == 0 && report.coverageComplete)
    }
    @Test func unsupportedResourcesReadFailuresAndIncompletePersonalProjectionsRemainVisible() async throws {
        let source = ReferenceFixtureSource([.init(text:"John3:16"),.init(text:"unreadable")],failed:[1])
        let doc = BibleReferencePersonalSource(documentID:UUID(),title:"Partial",fields:[],warnings:["Unsupported field retained"],projectionComplete:false)
        let report = try await BibleReferenceSearchService(provider:source).search(resources:[resource(),resource("Opaque",format:.logosModern)],documents:[doc],query:query("Jn3:16"))
        #expect(!report.coverageComplete && report.limitReason == nil && report.results.count == 1)
        #expect(report.resources[0].status == .partial && report.resources[0].articlesFailed == 1)
        #expect(report.resources[1].status == .incompatible && report.counters.resourcesIncompatible == 1)
        #expect(report.documents[0].warnings == ["Unsupported field retained"] && !report.documents[0].complete)
    }
    @Test func articleResultOccurrenceAndDurationBudgetsNeverClaimCompleteNegativeCoverage() async throws {
        let source = ReferenceFixtureSource([.init(text:"John3:16 John3:16"),.init(text:"John3:16")])
        let service = BibleReferenceSearchService(provider:source)
        let limited = try await service.search(resources:[resource()],query:query("Jn3:16"),budget:.init(maximumArticles:1))
        #expect(limited.limitReason == .articles && limited.results.count == 2 && !limited.coverageComplete)
        let one = try await service.search(resources:[resource()],query:query("Jn3:16"),budget:.init(maximumResults:1))
        #expect(one.limitReason == .results && one.results.count == 1 && !one.coverageComplete)
        let occurrence = try await service.search(resources:[resource()],query:query("Jn3:16"),budget:.init(maximumOccurrences:1))
        #expect(occurrence.limitReason == .occurrences && occurrence.results.count == 1)
        let slow = ReferenceFixtureSource([.init(text:"John3:16")],delay:.milliseconds(15))
        let timed = try await BibleReferenceSearchService(provider:slow).search(resources:[resource()],query:query("Jn3:16"),budget:.init(maximumDurationSeconds:0.001))
        #expect(timed.limitReason == .duration && timed.results.isEmpty && !timed.coverageComplete)
        let exact = try await BibleReferenceSearchService(provider:ReferenceFixtureSource([.init(text:"John3:16")])).search(resources:[resource()],query:query("Jn3:16"),budget:.init(maximumArticles:1,maximumResults:1,maximumOccurrences:1))
        #expect(exact.coverageComplete && exact.limitReason == nil && exact.results.count == 1)
    }
    @Test func sourceChangesDuringFinalProgressAndCancellationPropagateAsCriticalErrors() async throws {
        let source = ReferenceFixtureSource([.init(text:"John3:16")])
        do {
            _ = try await BibleReferenceSearchService(provider:source).search(resources:[resource()],query:query("Jn3:16"),onProgress:{ value in
                if value.counters.resourcesCompleted > 0 { await source.invalidate() }
            });Issue.record("Changed source produced a successful reference report")
        } catch let error as LegacyIndicesError { #expect(error == .sourceChanged) }
        let cancelled = Task { try await BibleReferenceSearchService(provider:ReferenceFixtureSource([.init(text:"Jn3:16")],delay:.milliseconds(50))).search(resources:[resource()],query:query("Jn3:16")) }
        cancelled.cancel()
        do { _ = try await cancelled.value;Issue.record("Cancelled reference search completed") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }
    @Test func duplicateScopesInvalidFieldsMalformedLinksAndInvalidBudgetsAreRejected() async throws {
        let service = BibleReferenceSearchService(provider:ReferenceFixtureSource([.init(text:"John3:16")]))
        await #expect(throws:(any Error).self) { try await service.search(resources:[resource(),resource()],query:query("Jn3:16")) }
        let doc = BibleReferencePersonalSource(documentID:UUID(),title:"Bad",fields:[.init(kind:.noteBody,text:"John3:16")])
        await #expect(throws:(any Error).self) { try await service.search(resources:[],documents:[doc],query:query("Jn3:16")) }
        await #expect(throws:(any Error).self) { try await service.search(resources:[resource()],query:query("Jn3:16"),budget:.init(maximumArticles:0)) }
        let malformed = ReferenceFixtureSource([.init(text:"😀 John3:16",referenceLinks:[.init(range:.init(location:1,length:1),target:"=rJn3:16")])])
        let report = try await BibleReferenceSearchService(provider:malformed).search(resources:[resource()],query:query("Jn3:16"))
        #expect(!report.coverageComplete && report.counters.articlesFailed == 1 && report.results.isEmpty)
    }
}
