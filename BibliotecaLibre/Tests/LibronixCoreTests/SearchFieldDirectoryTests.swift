import Foundation
import Testing
@testable import LibronixCore

@Suite struct SearchFieldDirectoryTests {
    private func search(_ source: String, _ text: String, _ fields: SearchFieldDirectory?) throws -> TextSearchResult {
        try TextSearchEngine.search(query:SearchQueryParser.parse(source),in:text,fields:fields)
    }
    @Test func explicitSourceFieldsDiscriminateIdenticalWordsAndKeepOriginalCoordinates() throws {
        let text="alpha\nbeta\nalpha gamma"
        let fields=SearchFieldDirectory(regions:[.title:[.init(location:0,length:5)],.body:[.init(location:6,length:4)],.footnote:[.init(location:11,length:11)]])
        #expect(try search("title:alpha",text,fields).hits.map(\.range.location) == [0])
        #expect(try search("body:alpha",text,fields).matchesQuery == false)
        #expect(try search("footnote:alpha",text,fields).hits.map(\.range.location) == [11])
        let compound=try search("title:alpha AND body:beta AND footnote:gamma",text,fields)
        #expect(compound.hits.map(\.range.location) == [0,6,17])
        #expect(try search("body:(beta AND NOT alpha)",text,fields).hits.map(\.range.location) == [6])
        #expect(try search("body:alpha OR title:alpha",text,fields).hits.map(\.range.location) == [0])
        let negative=try search("body:NOT alpha",text,fields)
        #expect(negative.matchesQuery && negative.hits.isEmpty)
    }
    @Test func unavailableFieldsCannotMasqueradeAsKnownEmptyEvenInNegativeOrBranches() throws {
        let text="alpha", unknown=SearchFieldDirectory(regions:[.body:[.init(location:0,length:5)]])
        #expect(throws:TextSearchError.fieldContextRequired) {try search("body:alpha",text,nil)}
        for query in ["footnote:alpha","footnote:NOT alpha","body:alpha OR footnote:beta"] {
            #expect(throws:TextSearchError.unsupportedField(.footnote)) {try search(query,text,unknown)}
        }
        let knownEmpty=SearchFieldDirectory(regions:[.footnote:[]])
        #expect(try search("footnote:alpha",text,knownEmpty).matchesQuery == false)
        let negative=try search("footnote:NOT alpha",text,knownEmpty)
        #expect(negative.matchesQuery && negative.hits.isEmpty)
    }
    @Test func fieldBoundariesAreLexicalBoundariesWithoutChangingUnqualifiedMatching() throws {
        let text="alphabeta", fields=SearchFieldDirectory(regions:[.title:[.init(location:0,length:5)],.body:[.init(location:5,length:4)]])
        #expect(try search("title:alpha",text,fields).hitCount == 1)
        #expect(try search("body:beta",text,fields).hits.map(\.range.location) == [5])
        #expect(try search("alpha",text,fields).matchesQuery == false)
        #expect(try search("beta",text,fields).matchesQuery == false)
        #expect(try search("title:alpha BEFORE/0 body:beta",text,fields).hitCount == 2)
    }
    @Test func disjointRegionsCannotBridgePhrasesOrPositionalWitnessesButBooleansCanUseBoth() throws {
        let text="alpha beta", fields=SearchFieldDirectory(regions:[.body:[.init(location:0,length:5),.init(location:6,length:4)]])
        #expect(try search("body:\"alpha beta\"",text,fields).matchesQuery == false)
        #expect(try search("body:(alpha BEFORE beta)",text,fields).matchesQuery == false)
        #expect(try search("body:(alpha AND beta)",text,fields).hitCount == 2)
        let whole=SearchFieldDirectory(regions:[.body:[.init(location:0,length:10)]])
        #expect(try search("body:\"alpha beta\"",text,whole).hitCount == 1)
        #expect(try search("body:(alpha BEFORE/0 beta)",text,whole).hitCount == 2)
    }
    @Test func graphemeBoundaryOverlapOrderingAndOverflowChecksRejectAmbiguousDirectories() throws {
        let text="😀 café note"
        for ranges:[SearchTextRange] in [[.init(location:1,length:1)],[.init(location:3,length:4)], [.init(location:3,length:5),.init(location:2,length:1)], [.init(location:3,length:5),.init(location:4,length:1)], [.init(location:0,length:0)], [.init(location:0,length:Int.max)]] {
            #expect(throws:TextSearchError.invalidFieldDirectory) {try SearchFieldDirectory(regions:[.body:ranges]).validate(in:text)}
        }
        let fields=SearchFieldDirectory(regions:[.title:[.init(location:3,length:5)],.heading:[.init(location:3,length:5)]])
        try fields.validate(in:text)
        #expect(try search("title:café",text,fields).hits.first?.range == .init(location:3,length:5))
        #expect(!fields.contains(.init(location:Int.max,length:2),in:.title))
    }
    @Test func fieldSyntaxUsesBoundedExplicitScopesAndPreservesUnicodeOperandSourceRanges() throws {
        let query=try SearchQueryParser.parse("body:\"😀\" OR heading:alpha")
        #expect(query.expression.requiredFields == [.body,.heading])
        guard case .disjunction(.field(.body,.phrase(let word)),.field(.heading,.term))=query.expression else {Issue.record("Wrong field AST");return}
        #expect(word.sourceRange == .init(location:5,length:4))
        for source in ["body:","body:(footnote:alpha)","body:body:alpha","unknown:alpha","BODY:alpha"] {
            #expect(throws:SearchQueryError.self) {try SearchQueryParser.parse(source)}
        }
        #expect(throws:SearchQueryError.self) {try SearchQueryParser.parse("body:body:body:alpha",limits:.init(maximumNesting:2))}
        #expect(throws:SearchQueryError.self) {try SearchQueryParser.parse("body:alpha",limits:.init(maximumNodes:1))}
    }
    @Test func fieldDirectoriesRoundTripAndAllUnqualifiedRegressionResultsStayIdentical() throws {
        let text="alpha beta gamma",fields=SearchFieldDirectory(regions:[.body:[.init(location:0,length:text.utf16.count)],.footnote:[]])
        let copy=try JSONDecoder().decode(SearchFieldDirectory.self,from:JSONEncoder().encode(fields));#expect(copy == fields)
        for source in ["alpha","alpha AND NOT absent","NOT absent","alpha BEFORE/0 beta","beta AFTER alpha","alpha OR (beta AND absent)","NOT NOT alpha"] {
            #expect(try search(source,text,fields) == search(source,text,nil))
        }
    }
}
