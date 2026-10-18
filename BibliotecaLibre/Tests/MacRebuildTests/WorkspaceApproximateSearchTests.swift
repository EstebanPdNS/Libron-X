import AppKit
import WebKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct WorkspaceApproximateSearchTests {
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Approximate search did not settle")
    }
    @Test func LiteralPhraseModeSelectsOriginalLegacyTextAndRestoresExactSearch() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [["😀 in the beginning", "unrelated ending"]]); defer { fixture.remove() }
        let search = WorkspaceSearchController(); search.resourceID = fixture.resources[0].id
        search.query = "\"in the begining\""; search.run(fixture.resources); try await settle { !search.isSearching }
        #expect(search.error == nil && search.coverageComplete && search.report?.results.isEmpty == true)
        search.query = "in the begining"; search.approximatePhrase = true; search.run(fixture.resources); try await settle { !search.isSearching }
        let hit = try #require(search.report?.results.first)
        #expect(search.error == nil && search.coverageComplete && search.report?.results.count == 1)
        let reader = ReaderSession(resource: fixture.resources[0]); reader.loadSearchResult(hit); try await settle { !reader.isLoading }
        #expect(reader.error == nil && reader.selectedText == "in the beginning" && reader.selectedRange.location == 3)
        search.query = "\"in the begining\""; search.approximatePhrase = false; search.run(fixture.resources); try await settle { !search.isSearching }
        #expect(search.error == nil && search.coverageComplete && search.report?.results.isEmpty == true)
    }
    @Test func ApproximateFieldPhrasesRemainInsideSharedHTMLArticlesAndLiteralOperatorText() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(chapterBody: "<span id='a1'></span><p>alpha AND beta</p><aside role='doc-footnote'>owned footnote</aside><span id='a2'></span><p>other body</p>")
        defer { fixture.remove() }
        let search = WorkspaceSearchController(); search.resourceID = fixture.resource.id; search.approximatePhrase = true
        search.query = "alpha AND beXa"; search.searchField = .body; search.run([fixture.resource]); try await settle { !search.isSearching }
        #expect(search.error == nil && search.coverageComplete && search.report?.results.count == 1 && search.report?.results[0].sectionOrdinal == 1)
        search.searchField = .footnote; search.query = "owned footnoXe"; search.run([fixture.resource]); try await settle { !search.isSearching }
        let hit = try #require(search.report?.results.first)
        #expect(search.coverageComplete && hit.sectionOrdinal == 1)
        let reader = ReaderSession(resource: fixture.resource); reader.loadSearchResult(hit); try await settle { !reader.isLoading }
        let page = try #require(reader.page?.oeb), path = try #require(page.book.path(for: page.url))
        let projection = try await ReaderOEBTextSource.shared.read(book: page.book, path: path, viewport: .init())
        try reader.acceptOEBProjection(projection.text, at: page.url)
        #expect(reader.selectedText == "owned footnote")
        search.searchField = nil; search.query = "footnote:owned"; search.run([fixture.resource]); try await settle { !search.isSearching }
        #expect(search.coverageComplete && search.report?.results.isEmpty == true)
        search.query = "footnoteother"; search.run([fixture.resource]); try await settle { !search.isSearching }
        #expect(search.coverageComplete && search.report?.results.isEmpty == true)
    }
    @Test func ShortPhrasesAndUnsafeEditSettingsFailBeforeSourceWork() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["abc"]]); defer { fixture.remove() }
        let search = WorkspaceSearchController(); search.resourceID = fixture.resources[0].id; search.approximatePhrase = true
        for (text, edits) in [("a", 1), ("abc", 3), ("abcdef", 4)] {
            search.query = text; search.maximumEdits = edits; search.run(fixture.resources)
            #expect(search.error != nil && !search.isSearching && search.report == nil && search.progress == nil)
        }
        search.query = "abc"; search.maximumEdits = 1; search.run(fixture.resources); try await settle { !search.isSearching }
        #expect(search.error == nil && search.coverageComplete && search.report?.results.count == 1)
    }
    @Test func LiteralQuotesBackslashesAndLongUnicodeInputDoNotBecomeQuerySyntax() async throws {
        _ = NSApplication.shared
        let text = #"alpha "beta" \ gamma"#
        let fixture = try AuthoredReaderFixture(documents: [[text]]); defer { fixture.remove() }
        let search = WorkspaceSearchController(); search.resourceID = fixture.resources[0].id
        search.approximatePhrase = true; search.query = #"alpha "beXa" \ gamma"#
        search.run(fixture.resources); try await settle { !search.isSearching }
        #expect(search.error == nil && search.coverageComplete && search.report?.results.count == 1)
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 60)
        search.query = family; search.run(fixture.resources); try await settle { !search.isSearching }
        #expect(search.error == nil && search.coverageComplete && search.report?.results.isEmpty == true)
    }

    @Test func AdjacentHTMLBlocksAndExplicitLineBreaksPreserveWholeWordSearch() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(chapterBody: "<span id='a1'></span><h1>Title</h1><p>😀 in the beginning</p><p>alpha<br/>beta<span style='display:inline-block'>Inline</span></p><span id='a2'></span><p>Other</p>")
        defer { fixture.remove() }
        let source = WorkspaceSearchReader(), prepared = try await source.prepare(fixture.resource)
        let article = try await source.read(fixture.resource, article: prepared.articles[1], prepared: prepared)
        #expect(article.text.contains("beginningalphabetaInline"))
        let search = WorkspaceSearchController(); search.resourceID = fixture.resource.id
        search.approximatePhrase = true; search.query = "in the begining"; search.run([fixture.resource]); try await settle { !search.isSearching }
        let hit = try #require(search.report?.results.first)
        #expect(search.coverageComplete && search.report?.results.count == 1)
        #expect((article.text as NSString).substring(with: hit.hits[0].range.nsRange) == "in the beginning")
        search.approximatePhrase = false; search.query = "alpha"; search.run([fixture.resource]); try await settle { !search.isSearching }
        #expect(search.coverageComplete && search.report?.results.count == 1)
        search.query = "beta"; search.run([fixture.resource]); try await settle { !search.isSearching }
        #expect(search.coverageComplete && search.report?.results.isEmpty == true) // Inline spans do not split a word.
    }

    @Test func XHTMLWithoutCharsetRendersTheSameUnicodeAsSearchAndSelectsItsActualDOM() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LibronixCoreTests/Fixtures/authored-stored.epub")
        let resource = LibraryResource(location: url, title: "Owned EPUB", byteCount: 0, format: .epub, support: .metadataOnly, provenance: .fileName)
        let search = WorkspaceSearchController(); search.resourceID = resource.id
        search.approximatePhrase = true; search.query = "AmoX 😀"; search.run([resource]); try await settle { !search.isSearching }
        let hit = try #require(search.report?.results.first)
        #expect(search.coverageComplete && search.report?.results.count == 1)
        let reader = ReaderSession(resource: resource); reader.loadSearchResult(hit); try await settle { !reader.isLoading }
        let coordinator = ReaderOEBView.Coordinator(reader: reader, activate: {})
        let view = ReaderOEBView.makeWebView(reader: reader, coordinator: coordinator)
        view.setFrameSize(NSSize(width: 760, height: 900))
        defer {
            view.stopLoading(); view.navigationDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: "reader", contentWorld: .defaultClient)
            reader.cancel()
        }
        coordinator.begin(try #require(reader.page?.oeb), in: view)
        try await settle { coordinator.ready }
        #expect(reader.error == nil && reader.selectedText == "Amor 😀")
        var selected: String?
        for _ in 0..<100 {
            selected = try await view.callAsyncJavaScript("return getSelection().toString();", in: nil, contentWorld: .defaultClient) as? String
            if selected == "Amor 😀" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(selected == "Amor 😀")
    }

}
