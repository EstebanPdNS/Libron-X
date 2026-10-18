import Foundation
import Testing
@testable import LibronixCore

struct BibliographyReportTests {
    private func resource(_ id:String,title:String="Known title",author:String?="Author",year:String?="2024",edition:String?="Second") -> LibraryResource {
        var m=LibronMetadata(title:title,origin:"Owned");m.authors=author.map { [$0] } ?? [];m.year=year;m.edition=edition
        m.evidence=[.init(field:"title",value:title,source:"owned:title"),.init(field:"authors",value:author ?? "",source:"owned:author")]
        return .init(location:URL(fileURLWithPath:"/owned/\(id).epub"),title:title,byteCount:0,format:.epub,support:.metadataOnly,provenance:.legacyPublicMetadata,libron:m)
    }
    @Test func realValuesRemainVerbatimAndMissingEditionDataIsNeverInvented() throws {
        var r=resource("one",title:"Título & Ελληνικά 😀",author:nil,year:nil,edition:nil)
        var m=try #require(r.libron);m.originalTitle="Original title";m.originalYear="1909, c1908";m.publisher="Publisher <original>";m.contributors=["Translator, T."];m.languages=["es","grc"]
        r = .init(location:r.location,title:r.title,byteCount:0,format:r.format,support:r.support,provenance:r.provenance,libron:m)
        let report=try BibliographyReportGenerator.generate(resources:[r],scope:.init(kind:.library,names:[],requestedCount:1))
        let row=try #require(report.entries.first)
        #expect(row.field(.title).text == "Título & Ελληνικά 😀" && row.field(.originalTitle).text == "Original title")
        #expect(row.field(.originalYear).text == "1909, c1908" && row.field(.publisher).text == "Publisher <original>")
        #expect(row.field(.authors).values.isEmpty && row.field(.year).certainty == .unknown && row.field(.edition).certainty == .unknown)
        #expect(row.field(.contributors).values == ["Translator, T."] && row.field(.languages).values == ["es","grc"])
        #expect(report.coverageComplete && report.entries.count == 1)
        #expect(!BibliographyReportRenderer.plainText(report).contains("Second"))
    }
    @Test func conflictingInferredCreditNeverBecomesDeclaredAndPendingFieldsStayUnverified() throws {
        let r=resource("one");var m=try #require(r.libron)
        m.evidence += [.init(field:"year",value:"2024",source:"embedded:publication",status:"inferred"),.init(field:"year",value:"2024",source:"embedded:year",status:"verified"),.init(field:"edition",value:"Second",source:"owned:edition")]
        m.pendingFields=["edition"]
        let value=LibraryResource(location:r.location,title:r.title,byteCount:0,format:r.format,support:r.support,provenance:r.provenance,libron:m)
        let report=try BibliographyReportGenerator.generate(resources:[value],scope:.init(kind:.selection,names:[],requestedCount:1))
        let row=try #require(report.entries.first)
        #expect(row.field(.year).certainty == .inferred && row.field(.year).evidence.count == 2)
        #expect(row.field(.edition).certainty == .unverified && row.field(.edition).pending)
        #expect(row.field(.title).certainty == .declared && row.field(.authors).certainty == .declared)
        #expect(report.inferredFieldCount == 1)
        let filename=LibraryResource(location:r.location,title:"Fallback filename",byteCount:0,format:r.format,support:r.support,provenance:.fileName)
        let fallback=try BibliographyReportGenerator.generate(resources:[filename],scope:.init(kind:.library,names:[],requestedCount:1))
        #expect(fallback.entries[0].field(.title).certainty == .unverified)
    }
    @Test func orderingIsDeterministicAndDistinctEditionIdentitiesNeverCollapse() throws {
        let a=resource("a",title:"Volume 10",author:"Zed",year:"2001"),b=resource("b",title:"Volume 2",author:"Alpha",year:"1999"),c=resource("c",title:"Volume 2",author:"Alpha",year:nil)
        let report=try BibliographyReportGenerator.generate(resources:[c,a,b],scope:.init(kind:.library,names:[],requestedCount:3))
        #expect(report.entries.map(\.id) == [b.id,c.id,a.id])
        let byTitle=report.ordered(by:.title),byYear=report.ordered(by:.yearTitle)
        #expect(byTitle.entries.map(\.id) == [b.id,c.id,a.id] && byYear.entries.map(\.id) == [b.id,a.id,c.id])
        #expect(byYear.id == report.id && byYear.sourceFingerprint == report.sourceFingerprint)
        let second=try BibliographyReportGenerator.generate(resources:[a,b,c],scope:report.scope,order:.title)
        #expect(second.sourceFingerprint == report.sourceFingerprint && second.entries.count == 3)
        #expect(throws:BibliographyReportError.duplicateIdentity) { try BibliographyReportGenerator.generate(resources:[a,a],scope:.init(kind:.library,names:[],requestedCount:2)) }
    }
    @Test func exportedJSONIsLosslessAndHTMLTreatsSourceMarkupAsText() throws {
        let r=resource("one",title:"<script>alert('source')</script> & \"quoted\"",author:"A\nB 😀",year:nil,edition:nil)
        let issues=[BibliographyScopeIssue(identity:"missing",title:"<img src=x onerror=bad>",reason:.missingResource)]
        let report=try BibliographyReportGenerator.generate(resources:[r],scope:.init(kind:.collections,names:["<Collection & one>"],requestedCount:2,issues:issues),generatedAt:Date(timeIntervalSince1970:123456))
        let json=try BibliographyReportRenderer.json(report),decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let decoded=try decoder.decode(BibliographyReport.self,from:json)
        #expect(decoded.entries == report.entries && decoded.scope == report.scope && decoded.sourceFingerprint == report.sourceFingerprint)
        let tree=try #require(JSONSerialization.jsonObject(with:json) as? [String:Any]);#expect(tree["coverageComplete"] as? Bool == false)
        let html=BibliographyReportRenderer.html(report)
        #expect(!html.contains("<script>") && !html.contains("<img src=x") && html.contains("&lt;script&gt;"))
        #expect(html.contains("&lt;Collection &amp; one&gt;") && html.contains("Content-Security-Policy") && html.contains("😀"))
        let text=BibliographyReportRenderer.plainText(report)
        #expect(text.contains(r.title) && text.contains("Unknown") && text.contains("Partial report"))
    }
    @Test func currentCatalogMetadataChangesFingerprintWithoutTouchingOrReadingBookFiles() throws {
        let a=resource("does-not-exist",year:"2001"),b=resource("does-not-exist",year:"2002")
        #expect(!FileManager.default.fileExists(atPath:a.location.path))
        let scope=BibliographyScope(kind:.selection,names:[],requestedCount:1)
        let first=try BibliographyReportGenerator.generate(resources:[a],scope:scope),second=try BibliographyReportGenerator.generate(resources:[b],scope:scope)
        #expect(first.sourceFingerprint != second.sourceFingerprint)
        #expect(first.entries[0].field(.year).text == "2001" && second.entries[0].field(.year).text == "2002")
    }
    @Test func emptyReportsAndUnsafeScopeOrMetadataHaveExplicitResults() throws {
        let empty=try BibliographyReportGenerator.generate(resources:[],scope:.init(kind:.library,names:[],requestedCount:0))
        #expect(empty.entries.isEmpty && empty.coverageComplete)
        let a=resource("one")
        #expect(throws:BibliographyReportError.invalidScope) { try BibliographyReportGenerator.generate(resources:[a],scope:.init(kind:.library,names:[],requestedCount:0)) }
        #expect(throws:BibliographyReportError.unsafeMetadata) { try BibliographyReportGenerator.generate(resources:[resource("a",title:"bad\0title")],scope:.init(kind:.library,names:[],requestedCount:1)) }
        #expect(throws:BibliographyReportError.unsafeMetadata) { try BibliographyReportGenerator.generate(resources:[resource("a",title:String(repeating:"a",count:64001))],scope:.init(kind:.library,names:[],requestedCount:1)) }
    }
    @Test func preCancelledGenerationCannotReturnEvenAnEmptyReport() async throws {
        let job=Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BibliographyReportGenerator.generate(resources:[],scope:.init(kind:.library,names:[],requestedCount:0))
        }
        do { _=try await job.value;Issue.record("Cancelled generation returned a report") }
        catch is CancellationError { }
    }

}
