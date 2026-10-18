import Foundation
import Testing
@testable import LibronixCore

@Suite struct SearchFieldIntegrationTests {
    private func metadata() -> SearchFieldDirectory {
        .init(regions:[.body:[.init(location:0,length:5)]],externalValues:[.title:["😀 Alpha"]])
    }
    private func search(_ source:String,fields:SearchFieldDirectory,options:TextSearchOptions = .init()) throws -> TextSearchResult {
        try TextSearchEngine.search(query:SearchQueryParser.parse(source),in:"beta!",options:options,fields:fields)
    }
    @Test func metadataMatchesUseTheirOwnCoordinatesAndNeverBecomeReaderHighlights() throws {
        let title=try search("title:Alpha",fields:metadata())
        #expect(title.matchesQuery && title.hits.isEmpty && title.hitCount == 1)
        #expect(title.externalHits[0].range == .init(location:3,length:5) && title.externalHits[0].value == "😀 Alpha")
        let mixed=try search("title:Alpha AND body:beta",fields:metadata())
        #expect(mixed.hitCount == 2 && mixed.hits[0].range == .init(location:0,length:4))
        #expect(mixed.externalHits[0].operands[0].text == "Alpha")
        let doubleNegative=try search("NOT NOT title:Alpha",fields:metadata())
        #expect(doubleNegative.externalHits[0].range == title.externalHits[0].range)
        #expect(doubleNegative.externalHits[0].operands[0].sourceRange == .init(location:14,length:5))
        let negative=try search("title:NOT absent",fields:metadata())
        #expect(negative.matchesQuery && negative.hits.isEmpty && negative.externalHits.isEmpty)
        #expect(try search("(title:absent AND body:beta) OR body:beta",fields:metadata()).externalHits.isEmpty)
    }
    @Test func nonVisibleMetadataCannotBeComparedToReaderPositions() throws {
        for source in ["title:Alpha BEFORE body:beta","title:(Alpha NEAR Alpha)","body:beta NEAR title:Alpha"] {
            #expect(throws:TextSearchError.nonPositionalField(.title)) {try search(source,fields:metadata())}
        }
    }
    @Test func metadataSharesWorkAndHitBudgetsWithVisibleText() throws {
        let fields=SearchFieldDirectory(regions:[.body:[.init(location:0,length:5)]],externalValues:[.title:["Alpha","Alpha"]])
        #expect(throws:TextSearchError.hitLimit) {try search("title:Alpha AND body:beta",fields:fields,options:.init(maximumHits:2))}
        #expect(throws:TextSearchError.workLimit) {try search("title:Alpha AND body:beta",fields:fields,options:.init(maximumMatchAttempts:2))}
        for values in [[String(repeating:"x",count:8193)],["bad\0value"],Array(repeating:"x",count:257)] {
            #expect(throws:TextSearchError.invalidFieldDirectory) {try SearchFieldDirectory(regions:[:],externalValues:[.title:values]).validate(in:"")}
        }
    }
    @Test func clippedFieldsRetainKnownEmptyAndMetadataWhileRebasingOnlyReaderRanges() throws {
        let text="prefix alpha middle beta suffix",source=text as NSString,scope=source.range(of:"middle beta")
        let fields=SearchFieldDirectory(regions:[.body:[.init(location:0,length:source.length)],.footnote:[.init(location:7,length:5)],.heading:[]],externalValues:[.title:["Owned"]])
        let clipped=try fields.clipped(to:.init(location:scope.location,length:scope.length),in:text)
        #expect(clipped.regions[.body] == [.init(location:0,length:scope.length)] && clipped.regions[.footnote] == [] && clipped.regions[.heading] == [])
        #expect(clipped.externalValues?[.title] == ["Owned"] && !clipped.supports(.quotation))
    }
    @Test func cachedFieldsMetadataAndUnknownChannelsSurviveReopening() async throws {
        let fixture=try PersistentLibrarySearchTests.Fixture(["beta!"]);defer{fixture.remove()}
        try fixture.replace([.init(text:"beta!",fieldDirectory:metadata())])
        let source=PersistentLibrarySearchTests.Source(projectionVersion:"owned-fields-v1")
        let provider=PersistentLibrarySearchProvider(source:source,directory:fixture.cache)
        let query=try SearchQueryParser.parse("title:Alpha AND body:beta")
        let initial=try await LibrarySearchService(provider:provider).search(resources:[fixture.resource],query:query)
        #expect(initial.coverageComplete && initial.results[0].hitCount == 2 && initial.results[0].externalHits.count == 1)
        await source.blockReads()
        let reopened=PersistentLibrarySearchProvider(source:source,directory:fixture.cache)
        let again=try await LibrarySearchService(provider:reopened).search(resources:[fixture.resource],query:query)
        #expect(again.coverageComplete && again.results == initial.results)
        let unsupported=try await LibrarySearchService(provider:reopened).search(resources:[fixture.resource],query:SearchQueryParser.parse("footnote:NOT absent"))
        #expect(!unsupported.coverageComplete && unsupported.results.isEmpty && unsupported.counters.articlesFailed == 1 && unsupported.counters.articlesRuledOutByIndex == 0)
    }
    @Test func externalHitsConsumeOccurrenceBudgetsAndOldArticleRecordsDecodeWithoutFields() async throws {
        let fixture=try PersistentLibrarySearchTests.Fixture(["beta!"]);defer{fixture.remove()}
        try fixture.replace([.init(text:"beta!",fieldDirectory:.init(regions:[:],externalValues:[.title:["Alpha Alpha"]]))])
        let service=LibrarySearchService(provider:PersistentLibrarySearchTests.Source())
        let result=try await service.search(resources:[fixture.resource],query:SearchQueryParser.parse("title:Alpha"),budget:.init(maximumOccurrences:1))
        #expect(!result.coverageComplete && result.limitReason == .occurrences && result.counters.occurrencesObserved == 2 && result.counters.occurrencesReturned == 1)
        #expect(result.results[0].hits.isEmpty && result.results[0].externalHits.count == 1)
        let old=Data(#"{"text":"old","warnings":[],"bibleVerses":[],"referenceAnchors":[]}"#.utf8)
        #expect(try JSONDecoder().decode(LibrarySearchDecodedArticle.self,from:old).fieldDirectory == nil)
    }
    @Test func explicitSourceUnitsConnectBodyWordsWithoutSearchingPresentationMarkers() throws {
        let text="a 16 b",parts:[SearchTextRange]=[.init(location:0,length:1),.init(location:5,length:1)]
        let fields=SearchFieldDirectory(regions:[.body:parts],witnessRegions:[.body:[.init(location:0,length:6)]])
        func run(_ source:String) throws -> TextSearchResult {try TextSearchEngine.search(query:SearchQueryParser.parse(source),in:text,fields:fields)}
        #expect(try run("body:(a BEFORE/0 b)").hitCount == 2)
        #expect(try run("a BEFORE/0 b").matchesQuery == false)
        #expect(try run("body:16").matchesQuery == false)
        #expect(try run("body:\"a 16 b\"").matchesQuery == false)
        #expect(throws:TextSearchError.invalidFieldDirectory) {
            try SearchFieldDirectory(regions:[.body:parts],witnessRegions:[.body:[.init(location:0,length:2)]]).validate(in:text)
        }
        let clipped=try fields.clipped(to:.init(location:5,length:1),in:text)
        #expect(clipped.regions[.body] == [.init(location:0,length:1)] && clipped.witnessRegions?[.body] == [.init(location:0,length:1)])
        #expect(try JSONDecoder().decode(SearchFieldDirectory.self,from:JSONEncoder().encode(fields)) == fields)
    }

}
