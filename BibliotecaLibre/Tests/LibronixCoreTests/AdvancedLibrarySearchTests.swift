import Foundation
import Testing
@testable import LibronixCore

@Suite struct AdvancedLibrarySearchTests {
    private func resource(_ title: String) -> LibraryResource {
        .init(location:URL(fileURLWithPath:"/tmp/advanced-owned/\(title).LSF"),title:title,byteCount:0,format:.legacyLSF,support:.metadataOnly,provenance:.fileName)
    }
    private func verse(_ ref: String, _ start: Int, _ length: Int) -> LibrarySearchBibleVerse {
        .init(reference:ref,normalizedReference:LegacyPassageQuery.parse(ref)!.normalizedKey,range:.init(location:start,length:length))
    }
    @Test func verseDistanceUsesCheckedSourceIntervalsAndNeverWidensVerseBooleanScopes() async throws {
        let book=resource("bible"), text="faith hope faith hope"
        let verses=[verse("John3:16",0,6),verse("John3:17",6,5),verse("John3:18",11,10)]
        let source=AdvancedSearchProvider(articles:[book.id:[.init(ordinal:0,text:text,bibleVerses:verses)]])
        let service=LibrarySearchService(provider:source), query=try SearchQueryParser.parse("faith WITHIN 1 VERSES hope")
        let article=try await service.search(resources:[book],query:query)
        #expect(article.coverageComplete && article.results.count == 1 && article.results[0].hitCount == 4)
        let single=try await service.search(resources:[book],query:query,unit:.bibleVerse)
        #expect(single.coverageComplete && single.results.map(\.bibleReference) == ["jn 3:18"])
        let range=try await service.search(resources:[book],query:query,unit:.bibleVerse,bibleRange:.parse("John3:16–17"))
        #expect(range.coverageComplete && range.results.isEmpty && range.counters.versesExamined == 2)
        let zero=try await service.search(resources:[book],query:SearchQueryParser.parse("faith WITHIN 0 VERSES hope"))
        #expect(zero.coverageComplete && zero.results[0].hits.map(\.range.location) == [11,17])
    }
    @Test func unanchoredAndIncompatibleChaptersProduceExplicitPartialCoverage() async throws {
        let unanchored=resource("unanchored"), crossed=resource("crossed")
        let source=AdvancedSearchProvider(articles:[unanchored.id:[.init(ordinal:0,text:"absent")],crossed.id:[.init(ordinal:0,text:"faith hope",bibleVerses:[verse("John3:16",0,6),verse("John4:1",6,4)])]])
        let result=try await LibrarySearchService(provider:source).search(resources:[unanchored,crossed],query:SearchQueryParser.parse("faith WITHIN 1 VERSES hope"))
        #expect(!result.coverageComplete && result.results.isEmpty && result.counters.articlesFailed == 2)
        #expect(result.resourceReports.allSatisfy { !$0.errors.isEmpty })
    }
    @Test func articleWindowsShiftVerseCoordinatesAndCannotJoinDifferentArticlesOrResources() async throws {
        let first=resource("one"), second=resource("two"), text="outside 😀 faith hope trailing"
        let range=(text as NSString).range(of:"faith hope")
        let source=AdvancedSearchProvider(articles:[first.id:[.init(ordinal:0,text:text,bibleVerses:[verse("Ge1:1",range.location,6),verse("Ge1:2",range.location+6,4)],searchRange:.init(location:range.location,length:range.length)),.init(ordinal:1,text:"faith"),.init(ordinal:2,text:"hope")],second.id:[.init(ordinal:0,text:"hope")]])
        let report=try await LibrarySearchService(provider:source).search(resources:[first,second],query:SearchQueryParser.parse("faith WITHIN 1 VERSES hope"))
        #expect(report.results.count == 1 && report.results[0].resourceID == first.id)
        #expect(report.results[0].hits.map(\.range.location) == [range.location,range.location+6])
        #expect(!report.coverageComplete && report.counters.articlesFailed == 3)
        let words=try await LibrarySearchService(provider:source).search(resources:[first,second],query:SearchQueryParser.parse("faith BEFORE/0 hope"))
        #expect(words.coverageComplete && words.results.count == 1 && words.results[0].hits.map(\.range.location) == [range.location,range.location+6])
    }
    @Test func persistentCandidatesRetainExactAdvancedResultsAndDoNotHideMissingVerseData() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let fixture = try PersistentLibrarySearchTests.Fixture(["faith hope","faith one two hope","other"])
        defer { fixture.remove() }
        let book=fixture.resource
        let source=PersistentLibrarySearchTests.Source()
        let linear=LibrarySearchService(provider:source)
        let indexed=LibrarySearchService(provider:PersistentLibrarySearchProvider(source:source,directory:root))
        for query in ["faith BEFORE/0 hope","faith NEAR/1 hope","hope AFTER faith","(faith BEFORE/0 hope) OR other","NOT (faith BEFORE/0 hope)","faith WITHIN 2 VERSES hope"] {
            let parsed=try SearchQueryParser.parse(query), expected=try await linear.search(resources:[book],query:parsed)
            for _ in 0..<2 {
                let actual=try await indexed.search(resources:[book],query:parsed)
                #expect(actual.results == expected.results && actual.coverageComplete == expected.coverageComplete)
                #expect(actual.counters.articlesFailed == expected.counters.articlesFailed)
                if parsed.expression.requiresVerseContext {#expect(actual.counters.articlesRuledOutByIndex == 0 && actual.counters.articlesFailed == 3)}
            }
        }
    }
}

private struct AdvancedSearchArticle: Sendable {
    let ordinal: Int
    let text: String
    var bibleVerses: [LibrarySearchBibleVerse] = []
    var searchRange: SearchTextRange? = nil
}
private actor AdvancedSearchProvider: LibrarySearchContentProvider {
    let articles: [String:[AdvancedSearchArticle]]
    init(articles:[String:[AdvancedSearchArticle]]) { self.articles=articles }
    func prepare(_ resource:LibraryResource) async throws -> LibrarySearchPreparedResource {
        .init(articles:articles[resource.id,default:[]].map { .init(sectionOrdinal:$0.ordinal,title:String($0.ordinal)) })
    }
    func read(_ resource:LibraryResource,article:LibrarySearchArticleDescriptor,prepared:LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
        let value=articles[resource.id]!.first { $0.ordinal==article.sectionOrdinal }!
        return .init(text:value.text,bibleVerses:value.bibleVerses,searchRange:value.searchRange)
    }
    func verifyUnchanged(_ resource:LibraryResource,prepared:LibrarySearchPreparedResource) async throws { try Task.checkCancellation() }
}
