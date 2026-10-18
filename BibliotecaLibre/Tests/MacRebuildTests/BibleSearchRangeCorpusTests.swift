import AppKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct BibleSearchRangeCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_BIBLE_RANGE_CORPUS"] != nil))
    func twoPassageRangesStayExactAcrossOriginalBibleFormatsAndSavedLists() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_BIBLE_RANGE_CORPUS"]))
        let resources = try LibronCatalog.load(from: root).resources
        let names = ["RVR60.LSF", "rvr60.lbxlls", "RVR95.LSF", "LBLA95.lbxlls", "NVI.lbxlls", "spanishrv.bbli"]
        var articles = 0, selected = 0, excluded = 0
        var formats = Set<ResourceFormat>()
        for (index, name) in names.enumerated() {
            let resource = try #require(resources.first { $0.location.lastPathComponent == name })
            var list = StudyDocument(title: "Authored acceptance range", kind: .verseList)
            list.verses = [.init(reference: "Ge1:1"), .init(reference: "Ge1:3")]
            let range = try index.isMultiple(of: 2) ? BibleSearchRange.parse("Genesis1:1,3") : BibleSearchRange.referenceList(list)
            let report = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [resource],
                query: SearchQueryParser.parse("NOT UnseenBibleRangeAcceptanceNeedle7f9"), unit: .bibleVerse, bibleRange: range,
                budget: .init(maximumDurationSeconds: 120, maximumArticles: 250_000, maximumResults: 500))
            #expect(report.coverageComplete, "Range failed for \(name): \(report.resourceReports.flatMap(\.errors).map(\.message))")
            #expect(report.results.map(\.bibleReference) == ["ge 1:1","ge 1:3"])
            #expect(report.counters.versesExamined == 2 && report.counters.versesExcludedByRange > 1000)
            for result in report.results {
                let visible = try await ReaderSession.read(resource, .init(ordinal: result.sectionOrdinal))
                let range = try #require(result.verseRange)
                #expect(result.decodedTextSHA256 == LibrarySearchService.textFingerprint(visible.text))
                #expect(range.upperBound <= visible.text.utf16.count && range.length > 0 && result.hits.isEmpty)
            }
            articles += report.counters.articlesExamined; selected += report.counters.versesExamined
            excluded += report.counters.versesExcludedByRange; formats.insert(resource.format)
            print("Bible range corpus resource \(name): \(report.counters.articlesExamined) articles, \(report.elapsedSeconds) seconds, \(report.counters.versesExamined) selected verses")
        }
        #expect(selected == 12 && formats.count == 3)
        print("Bible range corpus: \(names.count) resources, \(formats.count) original formats, \(articles) articles, \(selected) selected verses, \(excluded) excluded verses")
    }
}
