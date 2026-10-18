import Foundation
import Testing
@testable import LibronixCore

@Suite struct AdvancedTextSearchTests {
    private func search(_ query: String, _ text: String, verses: [LibrarySearchBibleVerse]? = nil,
                        options: TextSearchOptions = .init()) throws -> TextSearchResult {
        try TextSearchEngine.search(query: SearchQueryParser.parse(query), in: text, options: options, verses: verses)
    }
    private func texts(_ result: TextSearchResult, _ text: String) -> [String] {
        result.hits.map { (text as NSString).substring(with: $0.range.nsRange) }
    }
    @Test func parserBindsProximityMoreTightlyThanBooleanAndPreservesExplicitUnits() throws {
        let query = try SearchQueryParser.parse("alpha OR beta BEFORE 2 WORDS gamma AND NOT delta")
        guard case .disjunction(_, .conjunction(.proximity(let op,_,_),.negation)) = query.expression else { Issue.record("Wrong proximity precedence"); return }
        #expect(op.direction == .before && op.unit == .words && op.maximumDistance == 2)
        #expect((query.source as NSString).substring(with:op.sourceRange.nsRange) == "BEFORE 2 WORDS")
        guard case .proximity(let near,_,_) = try SearchQueryParser.parse("a NEAR b").expression else { Issue.record("Missing NEAR");return }
        #expect(near.maximumDistance == 48 && near.unit == .characters && near.direction == .either)
        guard case .proximity(let after,_,_) = try SearchQueryParser.parse("a AFTER/0 b").expression else { Issue.record("Missing AFTER");return }
        #expect(after.maximumDistance == 0 && after.unit == .words && after.direction == .after)
        #expect(try SearchQueryParser.parse("a WITHIN 2 VERSES b").expression.requiresVerseContext)
        #expect(try SearchQueryParser.parse("NOT (a WITHIN 2 VERSES b)").expression.requiresVerseContext)
        #expect(try !SearchQueryParser.parse("a BEFORE b").expression.requiresVerseContext)
    }
    @Test(arguments:["a WITHIN b","a WITHIN 2 b","a WITHIN 2 WORD b","a NEAR/-1 b","a NEAR/1000001 b","a NEAR/99999999999999999999999 b","a BEFORE 2.5 WORDS b","a BEFORE (b AND c)","(a AND b) NEAR c","a NEAR NOT b","NOT a BEFORE b","a WITHIN 0 VERSES", "a NEAR/ b"])
    func invalidOperatorsAndAmbiguousPositionalOperandsFailExplicitly(_ source: String) {
        #expect(throws:SearchQueryError.self) { try SearchQueryParser.parse(source) }
    }
    @Test func wordDistancesCountInterveningLexicalTokensAndKeepOnlyQualifyingWitnesses() throws {
        let source = "alpha one beta | alpha one two beta | beta alpha"
        let result = try search("alpha BEFORE/1 beta",source)
        #expect(texts(result,source) == ["alpha","beta"])
        #expect(try search("alpha BEFORE/0 beta","alpha, — beta").matchesQuery)
        #expect(try !search("alpha BEFORE/0 beta","alpha one beta").matchesQuery)
        #expect(try search("alpha BEFORE/1 beta","alpha can't beta").matchesQuery)
        #expect(try !search("alpha BEFORE/1 beta","alpha one two beta").matchesQuery)
        #expect(try search("alpha AFTER/0 beta","beta alpha").matchesQuery)
        #expect(try !search("alpha AFTER beta","alpha beta").matchesQuery)
        #expect(try search("alpha BEFORE beta","alpha one two three beta").matchesQuery)
    }
    @Test func characterDistancesUseOriginalUTF16GapsAndNoOccurrenceCanPairWithItself() throws {
        #expect(try search("alpha WITHIN 4 CHARACTERS beta","alpha 😀 beta").matchesQuery)
        #expect(try !search("alpha WITHIN 3 CHARACTERS beta","alpha 😀 beta").matchesQuery)
        #expect(try search("alpha NEAR/0 alpha","alpha alpha").hitCount == 2)
        #expect(try !search("alpha NEAR alpha","alpha").matchesQuery)
        #expect(try !search("\"alpha beta\" NEAR beta","alpha beta").matchesQuery)
        #expect(try search("alpha WITHIN 0 CHARACTERS beta","alphabeta",options:.init(wholeWords:false)).matchesQuery)
    }
    @Test func nestedWitnessesPreserveOrderAlternativesAndBooleanEvidence() throws {
        let source = "alpha beta gamma delta alpha far far beta"
        let result = try search("(alpha BEFORE/0 beta) BEFORE/0 gamma",source)
        #expect(texts(result,source) == ["alpha","beta","gamma"])
        #expect(try search("alpha BEFORE/0 (beta OR gamma)","alpha gamma").hitCount == 2)
        #expect(try !search("(alpha BEFORE/0 beta) BEFORE/0 gamma","alpha beta delta gamma").matchesQuery)
        let negative = try search("NOT (alpha BEFORE/0 beta)","alpha x beta")
        #expect(negative.matchesQuery && negative.hits.isEmpty)
        #expect(try search("NOT NOT (alpha BEFORE/0 beta)","alpha beta").hitCount == 2)
        let branches = try search("(alpha BEFORE/0 beta) OR gamma","alpha x beta gamma")
        #expect(texts(branches,"alpha x beta gamma") == ["gamma"])
        let identical = try search("alpha BEFORE/0 (beta OR beta)","alpha beta")
        #expect(identical.hits.count == 2 && identical.hits[1].operands.count == 2)
    }
    @Test func unicodePhrasesRetainGraphemesAndQueryOperandCoordinates() throws {
        let source = "😀 café λόγος extra café skip skip λόγος"
        let result = try search("café BEFORE/0 λόγος",source)
        #expect(texts(result,source) == ["café","λόγος"])
        #expect(result.hits[0].range == .init(location:3,length:5))
        #expect(result.hits[0].operands[0].sourceRange == .init(location:0,length:4))
        #expect(try search("\"alpha beta\" BEFORE/1 gamma","alpha beta one gamma").hitCount == 2)
        #expect(try !search("ALPHA BEFORE beta","alpha beta",options:.init(caseSensitive:true)).matchesQuery)
    }
    @Test func verseDistanceUsesActualNumberedAnchorsAndRejectsUnknownBoundaries() throws {
        let source = "alpha one beta gamma"
        func verse(_ n: Int, _ start: Int, _ length: Int, chapter: Int = 1) -> LibrarySearchBibleVerse {
            .init(reference:"Ge\(chapter):\(n)",normalizedReference:"ge \(chapter):\(n)",range:.init(location:start,length:length))
        }
        let verses = [verse(1,0,10),verse(3,10,10)]
        #expect(try !search("alpha WITHIN 1 VERSES beta",source,verses:verses).matchesQuery)
        #expect(try search("alpha WITHIN 2 VERSES beta",source,verses:verses).hitCount == 2)
        #expect(try search("beta WITHIN 0 VERSES gamma",source,verses:verses).hitCount == 2)
        #expect(throws:TextSearchError.verseContextRequired) { try search("alpha WITHIN 1 VERSES beta",source) }
        #expect(throws:TextSearchError.verseContextRequired) { try search("alpha WITHIN 1 VERSES beta",source,verses:[]) }
        #expect(throws:TextSearchError.unsupportedVerseBoundary) { try search("alpha WITHIN 1 VERSES beta",source,verses:[verse(1,0,10),verse(1,10,10,chapter:2)]) }
        #expect(throws:LibrarySearchError.invalidVerseDirectory) { try search("alpha WITHIN 1 VERSES beta",source,verses:[verse(3,0,10),verse(1,10,10)]) }
        #expect(throws:LibrarySearchError.invalidVerseDirectory) { try search("alpha WITHIN 1 VERSES beta",source,verses:[verse(1,0,15),verse(2,10,10)]) }
    }
    @Test func pairWorkHitAndCancellationBudgetsNeverReturnPartialSuccess() throws {
        let source = "alpha beta alpha beta alpha beta"
        #expect(throws:TextSearchError.workLimit) { try search("alpha BEFORE beta",source,options:.init(maximumMatchAttempts:5)) }
        #expect(throws:TextSearchError.hitLimit) { try search("alpha BEFORE beta",source,options:.init(maximumHits:3)) }
        #expect(throws:CancellationError.self) {
            try TextSearchEngine.search(query:SearchQueryParser.parse("alpha NEAR beta"),in:source,checkCancellation:{throw CancellationError()})
        }
    }
    @Test func independentBruteForceOracleDiscriminatesEveryWordDistanceAndDirection() throws {
        for words in [["alpha","beta","x","alpha","x","beta"],["beta","alpha","beta"],["alpha"],["beta","x","alpha"],["alpha","alpha","beta"]] {
            let source = words.joined(separator:" ")
            var offsets:[Int] = [], offset=0
            for word in words {offsets.append(offset);offset += word.utf16.count+1}
            for direction in ["NEAR","BEFORE","AFTER"] {
                for distance in 0...3 {
                    var expected=Set<Int>()
                    for a in words.indices where words[a]=="alpha" {
                        for b in words.indices where words[b]=="beta" {
                            let ordered=direction=="NEAR" || (direction=="BEFORE" && a<b) || (direction=="AFTER" && b<a)
                            if ordered && abs(a-b)-1<=distance {expected.insert(offsets[a]);expected.insert(offsets[b])}
                        }
                    }
                    let result=try search("alpha \(direction)/\(distance) beta",source)
                    #expect(result.matchesQuery == !expected.isEmpty)
                    #expect(Set(result.hits.map(\.range.location)) == expected)
                }
            }
        }
    }
}
