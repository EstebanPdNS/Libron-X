import AppKit
import Foundation
import Testing
import CSQLite
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct BibleSearchRangeWorkflowTests {
    private func bible(_ root: URL) throws -> LibraryResource {
        let url = root.appendingPathComponent("Owned.bbli")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK); defer { sqlite3_close(db) }
        let sql = "CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Owned range Bible','OB','Authored fixture'); CREATE TABLE Bible(Book,Chapter,Verse,Scripture); INSERT INTO Bible VALUES(1,1,1,'root'),(43,3,16,'😀 faith'),(43,3,17,'hope'),(43,3,18,'faith hope'),(45,8,1,'faith');"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return try ESwordResource.inspect(url)
    }
    private func settle(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Bible range workflow did not settle")
    }
    @Test func nativeAndRawRangesRetainVerseBoundariesAndNegativeResultsOpenTheActualVerse() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try bible(root), before = try Data(contentsOf: original.location)
        for normalized in [false, true] {
            let resource: LibraryResource
            if normalized {
                let package = try LibronPackage.create(original, in: root.appendingPathComponent("library"), backup: false)
                resource = try LibronPackage.read(package).1; _ = try await LibronNativeNormalizer().convert(resource)
            } else { resource = original }
            let service = LibrarySearchService(provider: WorkspaceSearchReader())
            let range = try BibleSearchRange.parse("John3:16–17")
            let crossed = try await service.search(resources: [resource], query: SearchQueryParser.parse("faith AND hope"), unit: .bibleVerse, bibleRange: range)
            #expect(crossed.coverageComplete && crossed.results.isEmpty && crossed.counters.versesExamined == 2)
            #expect(crossed.counters.versesExcludedByRange == 3)
            let negative = try await service.search(resources: [resource], query: SearchQueryParser.parse("NOT absent"), unit: .bibleVerse,
                bibleRange: .parse("John3:17"))
            let result = try #require(negative.results.first)
            #expect(result.hits.isEmpty && result.bibleReference == "jn 3:17")
            let reader = ReaderSession(resource: resource)
            reader.loadSearchResult(result); try await settle { !reader.isLoading }
            #expect(reader.error == nil && reader.selectedRange == result.verseRange?.nsRange)
            #expect(reader.selectedText.contains("hope") && !reader.selectedText.contains("faith"))
        }
        #expect(try Data(contentsOf: original.location) == before)
    }
    @Test func reopeningCachedVersesHonorsDifferentRangesAndSavedLists() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resource = try bible(root), cache = root.appendingPathComponent("indexes")
        let first = PersistentLibrarySearchProvider(source: WorkspaceSearchReader(), directory: cache)
        let whole = try await LibrarySearchService(provider: first).search(resources: [resource], query: SearchQueryParser.parse("faith"), unit: .bibleVerse)
        #expect(whole.coverageComplete && whole.results.count == 3)
        let warm = PersistentLibrarySearchProvider(source: WorkspaceSearchReader(), directory: cache)
        var list = StudyDocument(title: "Saved selection", kind: .verseList)
        list.verses = [.init(reference: "John3:16"), .init(reference: "Romans8")]
        let report = try await LibrarySearchService(provider: warm).search(resources: [resource], query: SearchQueryParser.parse("faith"), unit: .bibleVerse,
            bibleRange: .referenceList(list))
        #expect(report.coverageComplete && report.results.map(\.bibleReference) == ["jn 3:16","ro 8:1"])
        #expect(report.bibleRange?.sourceDocumentID == list.id && report.counters.versesExcludedByRange == 3)
        let metrics = await warm.metrics
        #expect(metrics.sourceReads == 0 && metrics.cachedReads == 3)
    }
    @Test func controllerAppliesCustomAndSavedScopesAndPreservesOrdinaryArticleSearch() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resource = try bible(root), controller = WorkspaceSearchController()
        controller.resourceID = resource.id; controller.query = "faith"; controller.bibleVerses = true
        controller.bibleRangeMode = .custom; controller.customBibleRange = "Romans8"
        controller.run([resource]); try await settle { !controller.isSearching }
        #expect(controller.error == nil && controller.report?.results.map(\.bibleReference) == ["ro 8:1"])
        var list = StudyDocument(title: "Selected verses", kind: .verseList)
        list.verses = [.init(reference: "John3:16")]
        controller.bibleRangeMode = .savedList; controller.referenceListID = list.id
        controller.run([resource], documents: [list]); try await settle { !controller.isSearching }
        #expect(controller.report?.results.map(\.bibleReference) == ["jn 3:16"])
        controller.run([resource], documents: []); try await settle { !controller.isSearching }
        #expect(controller.error != nil && controller.report == nil)
        controller.bibleVerses = false; controller.query = "faith AND hope"
        controller.run([resource]); try await settle { !controller.isSearching }
        #expect(controller.error == nil && controller.report?.unit == .article && controller.report?.bibleRange == nil)
        #expect(controller.report?.results.count == 1)
        controller.bibleVerses = true; controller.bibleRangeMode = .custom; controller.customBibleRange = "invalid scope"
        controller.run([resource]); try await settle { !controller.isSearching }
        #expect(controller.error != nil && controller.report == nil)
    }
    @Test func includedAndExcludedListsApplyToRealVerseBoundariesAndRestore() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resource = try bible(root), controller = WorkspaceSearchController()
        var includes = StudyDocument(title: "Included", kind: .verseList)
        includes.verses = [.init(reference: "John3:16–18"), .init(reference: "Romans8")]
        var excludes = StudyDocument(title: "Excluded", kind: .verseList)
        excludes.verses = [.init(reference: "John3:18"), .init(reference: "Romans8:1")]
        controller.resourceID = resource.id; controller.query = "faith"; controller.bibleVerses = true
        controller.bibleRangeMode = .savedList; controller.referenceListID = includes.id
        controller.excludedRange = .init(mode: .savedList, referenceListID: excludes.id)
        let configuration = controller.historyConfiguration
        controller.run([resource], documents: [includes, excludes]); try await settle { !controller.isSearching }
        #expect(controller.error == nil && controller.report?.results.map(\.bibleReference) == ["jn 3:16"])
        #expect(controller.report?.excludedBibleRange?.sourceDocumentID == excludes.id)
        #expect(controller.report?.counters.versesExcludedByRange == 3)
        controller.excludedRange = .init(); try controller.restore(configuration)
        #expect(controller.excludedRange.referenceListID == excludes.id && controller.excludedRange.mode == .savedList)
        controller.run([resource], documents: [includes]); try await settle { !controller.isSearching }
        #expect(controller.error != nil && controller.report == nil)
        controller.excludedRange = .init(mode: .custom, customRange: "John3:16")
        controller.bibleRangeMode = .all
        controller.run([resource]); try await settle { !controller.isSearching }
        #expect(controller.report?.results.map(\.bibleReference) == ["jn 3:18", "ro 8:1"])
    }
    @Test func namedRangesApplyAsInclusionAndExclusion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resource = try bible(root), search = WorkspaceSearchController()
        let include = NamedBibleSearchRange(name: "John", expression: "John3")
        let exclude = NamedBibleSearchRange(name: "First", expression: "John3:16")
        search.resourceID = resource.id; search.query = "faith"; search.bibleVerses = true
        search.bibleRangeMode = .namedRange; search.namedRangeID = include.id
        search.excludedRange = .init(mode: .namedRange, namedRangeID: exclude.id)
        let configuration = search.historyConfiguration
        search.run([resource], namedRanges: [include, exclude]); try await settle { !search.isSearching }
        #expect(search.error == nil && search.report?.results.map(\.bibleReference) == ["jn 3:18"])
        var old = NamedBibleSearchRanges(); old.ranges = [include, exclude]
        var revised = old; revised.ranges[0].expression = "John3:16"
        search.namedRangesChanged(from: old, to: revised)
        #expect(search.configurationChanged && !search.canOpenResults)
        try search.restore(configuration)
        #expect(search.namedRangeID == include.id && search.excludedRange.namedRangeID == exclude.id)
        search.run([resource], namedRanges: [include]); try await settle { !search.isSearching }
        #expect(search.error != nil && search.report == nil)
    }
}
