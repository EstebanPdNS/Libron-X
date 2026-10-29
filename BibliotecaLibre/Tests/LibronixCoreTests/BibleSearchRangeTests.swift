import Foundation
import Testing
@testable import LibronixCore

struct BibleSearchRangeTests {
    private func resource(_ name: String = "RVR60", abbreviation: String? = nil) -> LibraryResource {
        var metadata = LibronMetadata(title: name, origin: "Authored fixture"); metadata.abbreviation = abbreviation
        return .init(location: URL(fileURLWithPath: "/owned/\(name).LSF"), title: name, byteCount: 0,
                     format: .legacyLSF, support: .metadataOnly, provenance: .fileName, libron: metadata)
    }
    private func verse(_ reference: String, _ location: Int = 0, _ length: Int = 1) throws -> LibrarySearchBibleVerse {
        .init(reference: reference, normalizedReference: try #require(LegacyPassageQuery.parse(reference)).normalizedKey,
              range: .init(location: location, length: length))
    }
    private func article(_ entries: [(String, String)]) throws -> LibrarySearchDecodedArticle {
        var text = "😀 unanchored fear\n", intervals: [LibrarySearchBibleVerse] = []
        for (reference, body) in entries {
            intervals.append(try verse(reference, text.utf16.count, body.utf16.count + 1)); text += body + "\n"
        }
        return .init(text: text, bibleVerses: intervals)
    }
    actor Source: LibrarySearchContentProvider {
        let articles: [LibrarySearchDecodedArticle]
        var changed = false
        init(_ articles: [LibrarySearchDecodedArticle]) { self.articles = articles }
        func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
            .init(articles: articles.indices.map { .init(sectionOrdinal: $0, title: "Article \($0)") })
        }
        func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor, prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle { articles[article.sectionOrdinal] }
        func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws {
            try Task.checkCancellation(); if changed { throw LegacyIndicesError.sourceChanged }
        }
        func change() { changed = true }
    }
    private func search(_ source: Source, range: BibleSearchRange?, query: String = "faith",
                        book: LibraryResource? = nil, budget: LibrarySearchBudget = .init()) async throws -> LibrarySearchReport {
        try await LibrarySearchService(provider: source).search(resources: [book ?? resource()], query: SearchQueryParser.parse(query),
            unit: .bibleVerse, bibleRange: range, budget: budget)
    }
    @Test func wholeBooksMixWithPassagesAndInheritedReferenceLists() throws {
        let range = try BibleSearchRange.parse("Genesis, John3:16,18;4:1")
        let predicate = range.bind(to: resource())
        for value in ["Ge9:9", "Jn3:16", "Jn3:18", "Jn4:1"] { #expect(try predicate.contains(verse(value))) }
        for value in ["Ex1:1", "Jn3:17", "Jn4:2"] { #expect(try !predicate.contains(verse(value))) }
        let books = try BibleSearchRange.parse("Genesis\n\nJohn")
        #expect(try books.bind(to: resource()).contains(verse("John21:25")))
        #expect(try !books.bind(to: resource()).contains(verse("Romans1:1")))
        let boundary = try BibleSearchRange.parse("Mt28:20–Mr1:2").bind(to: resource())
        #expect(try boundary.contains(verse("Mt28:20")) && boundary.contains(verse("Mr1:2")))
        #expect(try !boundary.contains(verse("Mt28:19")) && !boundary.contains(verse("Mr1:3")))
    }
    @Test func overlappingAndDuplicateRangesAreMergedWithoutDuplicateVerseResults() async throws {
        let range = try BibleSearchRange.parse("John3:16–18; John3:17,18; John3:16")
        #expect(range.intervalCount == 1)
        let source = Source([try article([("Jn3:16", "faith"), ("Jn3:17", "faith"), ("Jn3:18", "faith")])])
        let report = try await search(source, range: range)
        #expect(report.coverageComplete && report.results.count == 3)
        #expect(Set(report.results.map(\.id)).count == 3 && report.counters.occurrencesReturned == 3)
        #expect(report.counters.versesExamined == 3 && report.counters.versesExcludedByRange == 0)
    }
    @Test func sourceEditionWinsAndUnqualifiedRangesRemainEditionIndependent() throws {
        let range = try BibleSearchRange.parse("John3:16(RVR60); John3:17(ESV)")
        #expect(try range.bind(to: resource()).contains(verse("Jn3:16")))
        #expect(try !range.bind(to: resource()).contains(verse("Jn3:17")))
        #expect(try range.bind(to: resource("renamed", abbreviation: "RVR60")).contains(verse("Jn3:16")))
        #expect(try !range.bind(to: resource("unknown")).contains(verse("Jn3:16")))
        #expect(try !range.bind(to: resource()).contains(verse("bible+esv.64.3.16")))
        #expect(try range.bind(to: resource()).contains(verse("bible+esv.64.3.17")))
        let general = try BibleSearchRange.parse("John3:16").bind(to: resource("unknown"))
        #expect(try general.contains(verse("bible+esv.64.3.16")))
    }
    @Test func booleanTermsNeverJoinSeparateVersesAndCoordinatesStayInTheFullSource() async throws {
        let decoded = try article([("Jn3:16", "faith"), ("Jn3:17", "hope"), ("Jn3:18", "faith hope")])
        let source = Source([decoded])
        let report = try await search(source, range: .parse("John3:16–17"), query: "faith AND hope")
        #expect(report.coverageComplete && report.results.isEmpty && report.counters.versesExamined == 2)
        #expect(report.counters.versesExcludedByRange == 1 && report.resourceReports[0].versesExcludedByRange == 1)
        let positive = try await search(source, range: .parse("John3:18"), query: "faith AND hope")
        let hit = try #require(positive.results.first)
        #expect(hit.verseRange == decoded.bibleVerses[2].range)
        #expect(hit.hits[0].range.location == decoded.bibleVerses[2].range.location)
        #expect(hit.decodedTextSHA256 == LibrarySearchService.textFingerprint(decoded.text))
        let negative = try await search(source, range: .parse("John3:16–17"), query: "NOT absent")
        #expect(negative.results.count == 2 && negative.results.allSatisfy { $0.hits.isEmpty && $0.verseRange != nil })
        #expect(try await search(source, range: .parse("John3"), query: "fear").results.isEmpty)
    }
    @Test func aRangeOutsideAnOtherwiseCompatibleBibleIsCompleteZeroCoverage() async throws {
        let source = Source([try article([("Jn3:16", "faith")])])
        let report = try await search(source, range: .parse("Romans8"))
        #expect(report.coverageComplete && report.results.isEmpty)
        #expect(report.resourceReports[0].status == .complete && report.counters.resourcesIncompatible == 0)
        #expect(report.counters.versesExamined == 0 && report.counters.versesExcludedByRange == 1)
        let nonBible = try await search(Source([.init(text: "faith")]), range: .parse("John3"))
        #expect(!nonBible.coverageComplete && nonBible.resourceReports[0].status == .incompatible)
    }
    @Test func savedListsAreImmutableAndRejectInvalidOrEmptyEntriesRatherThanOmittingThem() throws {
        var document = StudyDocument(title: "My passages", kind: .verseList)
        document.verses = [.init(reference: "John3:16"), .init(reference: "Genesis"), .init(reference: "bible+rvr60.64.3.18")]
        let original = try BibleSearchRange.referenceList(document)
        #expect(original.sourceDocumentID == document.id && original.sourceDocumentFingerprint != nil && original.referenceCount == 3)
        #expect(try original.bind(to: resource()).contains(verse("Jn3:18")))
        document.verses[0].reference = "John3:17"
        let changed = try BibleSearchRange.referenceList(document)
        #expect(changed.sourceDocumentFingerprint != original.sourceDocumentFingerprint)
        #expect(try original.bind(to: resource()).contains(verse("Jn3:16")))
        #expect(try !changed.bind(to: resource()).contains(verse("Jn3:16")))
        document.verses[1].reference = "some prose"
        #expect(throws: BibleSearchRangeError.invalidListEntry(2)) { try BibleSearchRange.referenceList(document) }
        document.verses = []
        #expect(throws: BibleSearchRangeError.emptyReferenceList) { try BibleSearchRange.referenceList(document) }
        #expect(throws: BibleSearchRangeError.notReferenceList) { try BibleSearchRange.referenceList(.init(title: "Notes", kind: .notebook)) }
    }
    @Test func logicalArticleScopesDoNotSearchOutsideTheirOwnVerseIntervals() async throws {
        let all = try article([("Jn3:16", "faith"), ("Jn3:17", "hope")])
        let scope = all.bibleVerses[1].range
        let scoped = LibrarySearchDecodedArticle(text: all.text, bibleVerses: all.bibleVerses, searchRange: scope)
        let report = try await search(Source([scoped]), range: .parse("John3"))
        #expect(report.coverageComplete && report.results.isEmpty && report.counters.versesExamined == 1)
        let cut = SearchTextRange(location: scope.location + 1, length: scope.length - 1)
        let partial = try await search(Source([.init(text: all.text, bibleVerses: all.bibleVerses, searchRange: cut)]), range: .parse("John3"))
        #expect(!partial.coverageComplete && partial.counters.articlesFailed == 1)
    }
    @Test func invalidExpressionsModesLimitsCancellationAndChangedSourcesAreExplicit() async throws {
        for input in ["", "John3:16,", ",Genesis", "Genesis;;John", "Jn3:18–16", "some prose", "Tob1:1–Jude1"] {
            #expect(throws: (any Error).self) { try BibleSearchRange.parse(input) }
        }
        #expect(throws: BibleSearchRangeError.tooLarge) { try BibleSearchRange.parse(String(repeating: "a", count: 16_000_001)) }
        #expect(throws: BibleSearchRangeError.tooLarge) { try BibleSearchRange.parse(String(repeating: ",", count: 100_001)) }
        let book = resource(), decoded = try article([("Jn3:16", "faith"), ("Jn3:17", "faith")])
        let source = Source([decoded, decoded]), range = try BibleSearchRange.parse("John3:16")
        await #expect(throws: BibleSearchRangeError.requiresVerseMode) {
            try await LibrarySearchService(provider: source).search(resources: [book], query: SearchQueryParser.parse("faith"), bibleRange: range)
        }
        await #expect(throws: BibleSearchRangeError.requiresVerseMode) {
            try await LibrarySearchService(provider: source).search(resources: [book], query: SearchQueryParser.parse("faith"), excludedBibleRange: range)
        }
        let limited = try await search(source, range: range, budget: .init(maximumArticles: 1))
        #expect(limited.truncated && !limited.coverageComplete && limited.results.count == 1)
        await #expect(throws: LegacyIndicesError.sourceChanged) {
            try await LibrarySearchService(provider: source).search(resources: [book], query: SearchQueryParser.parse("faith"), unit: .bibleVerse,
                bibleRange: range, onProgress: { value in if value.counters.articlesExamined == 2 { await source.change() } })
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BibleSearchRange.parse("Genesis; John3:16")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func largeSavedListsCompileOnceAndUseMergedIntervals() throws {
        var document = StudyDocument(title: "Authored large list", kind: .verseList)
        document.verses = (1...2000).map { .init(reference: "John3:\($0)") }
        let range = try BibleSearchRange.referenceList(document)
        #expect(range.referenceCount == 2000 && range.intervalCount == 2000)
        let predicate = range.bind(to: resource())
        #expect(try predicate.contains(verse("Jn3:1")) && predicate.contains(verse("Jn3:2000")))
        #expect(try !predicate.contains(verse("Jn3:2001")))
    }
    @Test func observedLLSSerializedAnchorsKeepTheirDatatypeAndSupportEditionSpecificRanges() async throws {
        let text = "😀 faith\nhope\n"
        let anchors: [LegacyReferenceAnchor] = [
            .init(reference: "bible+rvr60.64.3.16", flags: 0, dataTypeCode: 16, characterOffset: 3, decodedOffset: 0, referenceFormatFlags: 0),
            .init(reference: "bible+rvr60.64.3.17", flags: 0, dataTypeCode: 16, characterOffset: 9, decodedOffset: 0, referenceFormatFlags: 0),
            .init(reference: "John3:18", flags: 0, dataTypeCode: 16, characterOffset: 0, decodedOffset: 0),
            .init(reference: "page.4", flags: 0, dataTypeCode: 16, characterOffset: 0, decodedOffset: 0)
        ]
        let intervals = try BibleVerseText.intervals(text: text, anchors: anchors)
        #expect(intervals.map(\.normalizedReference) == ["jn 3:16","jn 3:17"])
        #expect(intervals.map(\.range) == [.init(location: 3, length: 6), .init(location: 9, length: 5)])
        #expect(anchors.allSatisfy { $0.dataTypeCode == 16 })
        let source = Source([.init(text: text, referenceAnchors: anchors)])
        let report = try await search(source, range: .parse("John3:16(RVR60)"), book: resource("different-file-name"))
        #expect(report.coverageComplete && report.results.count == 1 && report.results[0].hits[0].range.location == 3)
        let absent = try await search(source, range: .parse("John3:16(ESV)"), book: resource("ESV"))
        #expect(absent.coverageComplete && absent.results.isEmpty && absent.counters.versesExcludedByRange == 2)
    }
    @Test func observedESwordSecondAndThirdJohnAliasesMatchCanonicalSavedRanges() async throws {
        let source = Source([try article([("2Jo1:1", "faith"), ("3Jo1:1", "faith")])])
        let report = try await search(source, range: .parse("2 John; 3 Juan"))
        #expect(report.coverageComplete && report.results.map(\.bibleReference) == ["2jn 1:1", "3jn 1:1"])
        #expect(try BibleSearchRange.parse("2Jo1:1;3Jo1:1").intervalCount == 2)
    }
    @Test func repeatedMarkersCannotMergeDifferentExplicitEditionsOfTheSameVerse() throws {
        func anchor(_ edition: String, _ offset: Int) -> LegacyReferenceAnchor {
            .init(reference: "bible+\(edition).64.3.16", flags: 0, dataTypeCode: 16, characterOffset: offset, decodedOffset: 0)
        }
        #expect(throws: LibrarySearchError.invalidVerseDirectory) {
            try BibleVerseText.intervals(text: "faith hope", anchors: [anchor("rvr60", 0), anchor("esv", 6)])
        }
        let repeated = try BibleVerseText.intervals(text: "faith hope", anchors: [anchor("RVR60", 0), anchor("rvr60", 6)])
        #expect(repeated.count == 1 && repeated[0].range.length == 10)
    }
}
