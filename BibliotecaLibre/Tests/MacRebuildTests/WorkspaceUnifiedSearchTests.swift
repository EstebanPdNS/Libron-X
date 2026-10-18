import AppKit
import Foundation
import Testing
import LibronixCore
import CSQLite
@testable import MacRebuild

@Suite(.serialized) @MainActor struct WorkspaceUnifiedSearchTests {
    private func query(_ text: String) throws -> SearchQuery { try SearchQueryParser.parse(text) }
    private func bible(in root: URL) throws -> LibraryResource {
        let source = root.appendingPathComponent("owned.bbli")
        var db: OpaquePointer?
        #expect(sqlite3_open(source.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Owned Bible','OB','Fixture'); CREATE TABLE Bible(Book,Chapter,Verse,Scripture); INSERT INTO Bible VALUES(1,1,1,'😀 Gamma faith'),(1,1,2,'hope'),(1,2,1,'Gamma faith hope');", nil, nil, nil) == SQLITE_OK)
        return try ESwordResource.inspect(source)
    }
    private func settle(_ reader: ReaderSession) async throws {
        for _ in 0..<2000 {
            if !reader.isLoading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Search result navigation did not finish")
    }

    @Test func mixedLegacyAndESwordSearchUsesVisibleTextAndVerseBoundaries() async throws {
        _ = NSApplication.shared
        let legacy = try AuthoredReaderFixture(documents: [["Gamma 😀", "Other section"]]); defer { legacy.remove() }
        let esword = try bible(in: legacy.root)
        let report = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(
            resources: legacy.resources + [esword], query: query("Gamma"))
        #expect(report.coverageComplete && report.results.count == 3)
        #expect(Set(report.results.map(\.resourceID)) == Set([legacy.resources[0].id, esword.id]))
        #expect(report.counters.resourcesIncompatible == 0 && report.counters.articlesFailed == 0)
        let verse = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(
            resources: [esword], query: query("faith AND hope"), unit: .bibleVerse)
        #expect(verse.coverageComplete && verse.results.count == 1)
        #expect(verse.results.first?.bibleReference == "ge 2:1")
        #expect(verse.counters.versesExamined == 3)
    }

    @Test func nativeESwordResultsOpenExactUnicodeSelectionAndRejectChangedDatabase() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try bible(in: root)
        let package = try LibronPackage.create(source, in: root.appendingPathComponent("library"), backup: false)
        let resource = try LibronPackage.read(package).1
        _ = try await LibronNativeNormalizer().convert(resource)
        let before = try LibronPackage.hash(resource.location)
        let report = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [resource], query: query("Gamma"))
        #expect(report.coverageComplete && report.results.count == 2)
        let hit = try #require(report.results.first)
        #expect(hit.sourceStamps.count == 3)
        let reader = ReaderSession(resource: resource)
        reader.loadSearchResult(hit); try await settle(reader)
        #expect(reader.error == nil && reader.selectedText == "Gamma")
        #expect(reader.selectedRange.location == (reader.page!.text as NSString).range(of: "Gamma").location)
        #expect(reader.selectedRange.location > reader.page!.text.distance(from: reader.page!.text.startIndex, to: reader.page!.text.range(of: "Gamma")!.lowerBound)) // UTF-16 includes the surrogate pair
        let committed = reader.page?.text, history = reader.history
        let native = try #require(LibronNativeReader.location(resource))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: native.path)
        reader.loadSearchResult(hit); try await settle(reader)
        #expect(reader.error != nil && reader.page?.text == committed && reader.history == history)
        #expect(try LibronPackage.hash(resource.location) == before)
    }

    @Test func sharedHTMLArticlesHaveNoDuplicateHitsOrCrossArticleBooleanMatches() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(); defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.resource.location)
        for normalized in [false, true] {
            let resource: LibraryResource
            if normalized {
                let package = try LibronPackage.create(fixture.resource, in: fixture.root.appendingPathComponent("library"), backup: false)
                resource = try LibronPackage.read(package).1
                _ = try await LibronNativeNormalizer().convert(resource)
            } else { resource = fixture.resource }
            let report = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [resource], query: query("Gamma"), options: .init(wholeWords: false))
            #expect(report.coverageComplete && report.results.map(\.sectionOrdinal) == [1, 2, 3])
            #expect(report.results.map(\.hitCount) == [3, 1, 1])
            let second = try #require(report.results.first { $0.sectionOrdinal == 2 })
            #expect(second.hits.first!.range.location > 0)
            #expect(second.snippet.text == "SecondGamma second")
            let noCross = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [resource], query: query("Delta AND second"), options: .init(wholeWords: false))
            #expect(noCross.coverageComplete && noCross.results.isEmpty)
            let hidden = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [resource], query: query("InvisibleNeedle"))
            #expect(hidden.coverageComplete && hidden.results.isEmpty)
            let reader = ReaderSession(resource: resource)
            reader.loadSearchResult(second); try await settle(reader)
            let page = try #require(reader.page?.oeb)
            let projected = try await ReaderOEBTextSource.shared.read(book: page.book, path: "Chapter.html", viewport: .init())
            try reader.acceptOEBProjection(projected.text, at: page.url)
            #expect(reader.selectedText == "Gamma" && reader.selectedRange == second.hits.first?.range.nsRange)
        }
        #expect(try Data(contentsOf: fixture.resource.location) == original)
    }

    @Test func epubAndNativeDictionariesJoinGlobalSearchWithoutStrippingHTML() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let epubURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LibronixCoreTests/Fixtures/authored-stored.epub")
        let epub = LibraryResource(location: epubURL, title: "Owned EPUB", byteCount: 0, format: .epub, support: .metadataOnly, provenance: .fileName)
        let dictURL = root.appendingPathComponent("dictionary.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(dictURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version=1; CREATE TABLE entries(ordinal INTEGER PRIMARY KEY,headword TEXT,body TEXT); INSERT INTO entries VALUES(0,'amor','Amor 😀 definición'),(1,'other','Other definition');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let dict = LibraryResource(location: dictURL, title: "Owned dictionary", byteCount: 0, format: .libronDictionary, support: .metadataOnly, provenance: .fileName)
        let report = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [epub, dict], query: query("Amor"), options: .init(wholeWords: false))
        #expect(report.coverageComplete && Set(report.results.map(\.resourceID)) == Set([epub.id, dict.id]))
        #expect(report.results.allSatisfy { $0.hits.allSatisfy { $0.range.length == 4 } })
        let package = try LibronPackage.create(epub, in: root.appendingPathComponent("library"), backup: false)
        let native = try LibronPackage.read(package).1
        _ = try await LibronNativeNormalizer().convert(native)
        let converted = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [native], query: query("Amor"), options: .init(wholeWords: false))
        #expect(converted.coverageComplete && converted.results.map(\.hitCount) == report.results.filter { $0.resourceID == epub.id }.map(\.hitCount))
    }

    @Test func unsupportedCorruptChangedAndCancelledSourcesNeverReportCompleteCoverage() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(); defer { fixture.remove() }
        let unsupported = LibraryResource(location: fixture.root.appendingPathComponent("x.logos4"), title: "Unsupported", byteCount: 0, format: .logosModern, support: .opaqueContainer, provenance: .fileName)
        let incompatible = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [unsupported], query: query("Gamma"))
        #expect(!incompatible.coverageComplete && incompatible.counters.resourcesIncompatible == 1)
        let provider = WorkspaceSearchReader(), prepared = try await provider.prepare(fixture.resource)
        try Data("corrupt source".utf8).write(to: fixture.resource.location, options: .atomic)
        await #expect(throws: LegacyIndicesError.sourceChanged) { try await provider.verifyUnchanged(fixture.resource, prepared: prepared) }
        let corrupt = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [fixture.resource], query: query("Gamma"))
        #expect(!corrupt.coverageComplete && corrupt.counters.resourcesFailed == 1)
        let task = Task { try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [unsupported], query: query("Gamma")) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_UNIFIED_SEARCH_CORPUS"] != nil))
    func managedCorpusFirstAndLastArticlesUseMatchingReaderCoordinates() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_UNIFIED_SEARCH_CORPUS"]))
        let resources = try LibronCatalog.load(from: root).resources
        let provider = WorkspaceSearchReader()
        var checked = 0, formats = Set<ResourceFormat>()
        for resource in resources {
            #expect(await provider.supports(resource))
            let prepared = try await provider.prepare(resource)
            for descriptor in [prepared.articles.first, prepared.articles.last].compactMap({ $0 }) {
                let decoded = try await provider.read(resource, article: descriptor, prepared: prepared)
                let visible = try await ReaderSession.read(resource, .init(ordinal: descriptor.sectionOrdinal))
                if let html = visible.oeb {
                    let path = try #require(html.book.path(for: html.url))
                    let projection = try await ReaderOEBTextSource.shared.read(book: html.book, path: path, viewport: .init())
                    #expect(decoded.text == projection.text)
                    #expect(decoded.searchRange?.nsRange == projection.articleRanges[descriptor.sectionOrdinal])
                } else {
                    #expect(decoded.text == visible.text && decoded.searchRange == nil)
                    if resource.format == .eSwordSQLite {
                        #expect(decoded.bibleVerses.count == ReaderBibleIndex(anchors: visible.content?.anchors ?? [], textLength: visible.text.utf16.count).entries.count)
                    } else { #expect(decoded.referenceAnchors == visible.content?.anchors ?? []) }
                }
                checked += 1
            }
            try await provider.verifyUnchanged(resource, prepared: prepared)
            formats.insert(resource.format)
        }
        #expect(resources.count > 0 && checked == resources.count * 2)
        print("Unified search corpus: \(resources.count) resources, \(checked) first/last article projections, \(formats.count) original formats")
    }

    @Test func persistentHTMLAndNativeBibleSearchesKeepIdenticalResultsAfterReopening() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(); defer { fixture.remove() }
        let cache = fixture.root.appendingPathComponent("search-index")
        let bibleSource = try bible(in: fixture.root)
        let package = try LibronPackage.create(bibleSource, in: fixture.root.appendingPathComponent("library"), backup: false)
        let nativeBible = try LibronPackage.read(package).1
        _ = try await LibronNativeNormalizer().convert(nativeBible)
        let resources = [fixture.resource, nativeBible]
        let cold = PersistentLibrarySearchProvider(source: WorkspaceSearchReader(), directory: cache)
        let first = try await LibrarySearchService(provider: cold).search(resources: resources, query: query("NOT UnseenIndexFixtureNeedle"))
        #expect(first.coverageComplete && first.counters.articlesExamined == 6)
        let warm = PersistentLibrarySearchProvider(source: WorkspaceSearchReader(), directory: cache)
        for expression in ["Gamma", "Delta AND second", "faith AND hope", "NOT faith", "café"] {
            let options = TextSearchOptions(wholeWords: false)
            let original = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: resources, query: query(expression), options: options)
            let indexed = try await LibrarySearchService(provider: warm).search(resources: resources, query: query(expression), options: options)
            #expect(indexed.results == original.results && indexed.coverageComplete)
        }
        let sourceMetrics = await warm.metrics
        #expect(sourceMetrics.sourceReads == 0 && sourceMetrics.cacheFailures == 0 && sourceMetrics.cachedReads > 0)
        let verse = try await LibrarySearchService(provider: warm).search(resources: [nativeBible], query: query("faith AND hope"), unit: .bibleVerse)
        #expect(verse.coverageComplete && verse.results.map(\.bibleReference) == ["ge 2:1"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_PERSISTENT_SEARCH_CORPUS"] != nil))
    func installedCorpusIndexedResultsMatchLinearEvaluationAcrossAllOriginalFormats() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_PERSISTENT_SEARCH_CORPUS"]))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("owned-real-index-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let resources = try LibronCatalog.load(from: root).resources
        var choices: [ResourceFormat: (Int, LibraryResource)] = [:]
        for resource in resources {
            guard let package = resource.packageLocation,
                  let data = try? Data(contentsOf: package.appendingPathComponent("normalized/conversion.json")),
                  let receipt = try? JSONDecoder().decode(LibronNormalizationReceipt.self, from: data),
                  (2...50).contains(receipt.sections) else { continue }
            if receipt.sections < (choices[resource.format]?.0 ?? Int.max) { choices[resource.format] = (receipt.sections, resource) }
        }
        #expect(Set(choices.keys) == Set([ResourceFormat.legacyLSF, .libronixLLS, .libronixOEB, .eSwordSQLite]))
        var checkedArticles = 0, comparedQueries = 0
        for (_, resource) in choices.values.sorted(by: { $0.1.id < $1.1.id }) {
            let cold = PersistentLibrarySearchProvider(source: WorkspaceSearchReader(), directory: cache)
            let built = try await LibrarySearchService(provider: cold).search(resources: [resource], query: query("NOT UnseenIndexFixtureNeedle"))
            #expect(built.coverageComplete)
            checkedArticles += built.counters.articlesExamined
            let warm = PersistentLibrarySearchProvider(source: WorkspaceSearchReader(), directory: cache)
            for expression in ["a", "Dios OR Bible", "NOT Dios"] {
                let options = TextSearchOptions(wholeWords: false)
                let original = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [resource], query: query(expression), options: options)
                let actual = try await LibrarySearchService(provider: warm).search(resources: [resource], query: query(expression), options: options)
                #expect(actual.results == original.results && actual.coverageComplete == original.coverageComplete)
                comparedQueries += 1
            }
            let metrics = await warm.metrics
            #expect(metrics.sourceReads == 0 && metrics.cacheFailures == 0)
        }
        print("Persistent search corpus: \(choices.count) original formats, \(checkedArticles) indexed articles, \(comparedQueries) complete indexed/linear comparisons")
    }

}
