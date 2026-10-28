import Foundation
import Testing
@testable import LibronixCore

struct BiblePassageReportTests {
    private func resource(_ title: String = "Authored edition") -> LibraryResource {
        .init(location: URL(fileURLWithPath: "/fixture/edition.LSF"), title: title, byteCount: 0,
              format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
    }
    private func article(_ values: [(String, String)]) throws -> LibrarySearchDecodedArticle {
        var text = "😀 Article heading\n", verses: [LibrarySearchBibleVerse] = []
        for (reference, body) in values {
            verses.append(.init(reference: reference, normalizedReference: try #require(LegacyPassageQuery.parse(reference)).normalizedKey,
                range: .init(location: text.utf16.count, length: body.utf16.count)))
            text += body
        }
        return .init(text: text, bibleVerses: verses)
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
            if changed { throw LegacyIndicesError.sourceChanged }
        }
        func change() { changed = true }
    }
    @Test func explicitMissingVersesAndSourceEditionLabelsRemainDistinct() async throws {
        let decoded = try article([("Ge1:1", "😀 First\n"), ("Ge1:3", "Third\n")])
        let report = try await BiblePassageReportService(provider: Source([decoded])).read(resource(), range: .parse("Ge1:1-3"))
        #expect(report.complete && report.failure == nil && report.verses.count == 2)
        #expect(report.verses[0].sourceRange.location == "😀 Article heading\n".utf16.count)
        #expect(report.verses[0].sourceFingerprint == LibrarySearchService.textFingerprint(decoded.text))
        #expect(BiblePassageReport.references(in: [report], requested: "Ge1:1-3").count == 3)
        let csv = BiblePassageReport.csv(editions: [report], requested: "Ge1:1-3")
        #expect(csv.contains("\"missing\"") && csv.contains("😀 First\n"))
        let explicit = try article([("bible+esv.64.3.16", "owned text")])
        let edition = try await BiblePassageReportService(provider: Source([explicit])).read(resource(), range: .parse("John3:16"))
        #expect(edition.verses.first?.reference == "bible+esv.64.3.16")
    }
    @Test func partialOrChangedSourcesNeverClaimMissingVerses() async throws {
        let decoded = try article([("Ge1:1", "First")]), source = Source([decoded, try article([("Ge1:2", "Second")])])
        let service = BiblePassageReportService(provider: source)
        let partial = try await service.read(resource(), range: .parse("Ge1:1-3"), maximumArticles: 1)
        #expect(!partial.complete && partial.verses.count == 1)
        #expect(BiblePassageReport.csv(editions: [partial], requested: "Ge1:1-3").contains("\"unverified\""))
        #expect(!BiblePassageReport.csv(editions: [partial], requested: "Ge1:1-3").contains("\"missing\""))
        await source.change()
        let changed = try await service.read(resource(), range: .parse("Ge1:1-3"))
        #expect(!changed.complete && changed.verses.isEmpty && changed.failure != nil)
        let duplicate = try await BiblePassageReportService(provider: Source([decoded, decoded])).read(resource(), range: .parse("Ge1"))
        #expect(!duplicate.complete && duplicate.verses.isEmpty && duplicate.failure != nil)
    }
    @Test func listReportPreservesDuplicatesAndSeparatesInvalidMissingAndChangedSources() async throws {
        let decoded = try article([("Ge1:1", "First"), ("Ge1:3", "Third")])
        let source = Source([decoded]), service = StudyVerseListReportService(provider: source)
        var doc = StudyDocument(title: "Own list", kind: .verseList)
        doc.verses = [StudyVerseEntry(reference: "Ge1:1-3"), StudyVerseEntry(reference: "Ge1:1"),
                      StudyVerseEntry(reference: "Ge1:2"), StudyVerseEntry(reference: "unknown")]
        let report = try await service.read(doc, resource: resource())
        #expect(report.rows.map(\.entryID) == doc.verses.map(\.id))
        #expect(report.rows.map(\.state) == [.partial, .available, .missing, .invalid])
        #expect(report.rows[0].verses.map(\.text) == ["First", "Third"])
        #expect(report.rows[1].verses.map(\.text) == ["First"])
        await source.change()
        let changed = try await service.read(doc, resource: resource())
        #expect(changed.rows.map(\.state) == [.unverified, .unverified, .unverified, .invalid])
        #expect(changed.rows.allSatisfy { $0.verses.isEmpty })
    }
    @Test func listReportHonorsExplicitEditions() async throws {
        let decoded = try article([("bible+esv.64.3.16", "Source edition text")])
        var doc = StudyDocument(title: "Editions", kind: .verseList)
        doc.verses = [StudyVerseEntry(reference: "John 3:16(esv)"), StudyVerseEntry(reference: "John 3:16(other)")]
        let report = try await StudyVerseListReportService(provider: Source([decoded])).read(doc, resource: resource())
        #expect(report.rows.map(\.state) == [.available, .unverified])
        #expect(report.rows[0].verses.first?.reference == "bible+esv.64.3.16")
    }
    @Test func sourceFieldsExcludeEditorialTextAndExportPreservesQuotesAndUnicode() async throws {
        let decoded = try article([("Ge1:1", "=formula,\"owned\" 😀\nnote")])
        let verse = decoded.bibleVerses[0], range = SearchTextRange(location: verse.range.location, length: verse.range.length - 4)
        let filtered = LibrarySearchDecodedArticle(text: decoded.text, bibleVerses: decoded.bibleVerses,
            fieldDirectory: .init(regions: [.bibleText: [range]]))
        let report = try await BiblePassageReportService(provider: Source([filtered])).read(resource(), range: .parse("Ge1:1"))
        #expect(report.complete && report.verses.first?.text == "=formula,\"owned\" 😀\n")
        let csv = BiblePassageReport.csv(editions: [report], requested: "Ge1:1")
        #expect(csv.contains("\"'=formula,\"\"owned\"\" 😀\n\""))
        #expect(csv.hasSuffix("\r\n") && !csv.contains("note"))
    }
}
