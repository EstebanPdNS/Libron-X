import AppKit
import WebKit
import Testing
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct ReaderOEBFindCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_OEB_FIND_MEDIA"] != nil))
    func everyOriginalArticleHasOneContiguousRenderedSearchSpan() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_OEB_FIND_MEDIA"]))
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "lbxoeb" }.sorted { $0.path < $1.path }
        let service = LibronixOEBService(), textSource = ReaderOEBTextSource()
        var rows: [[String: Any]] = [], articleCount = 0
        for (index, file) in files.enumerated() {
            let book = try await service.prepare(file)
            var covered = Set<Int>()
            for path in book.directory.files {
                let page = try await textSource.read(book: book, path: path, viewport: .init())
                var cursor = 0
                for (ordinal, span) in page.articleRanges.sorted(by: { $0.key < $1.key }) {
                    #expect(span.location == cursor)
                    #expect(covered.insert(ordinal).inserted)
                    cursor = NSMaxRange(span)
                }
                #expect(cursor == page.text.utf16.count)
                rows.append(["resource": file.path.replacingOccurrences(of: root.path + "/", with: ""), "page": path,
                    "articles": page.articleRanges.count, "textUTF16": page.text.utf16.count, "fingerprint": page.fingerprint, "passed": cursor == page.text.utf16.count])
            }
            #expect(covered == Set(book.directory.articles.map(\.ordinal)))
            articleCount += covered.count
            print("OEB native Find corpus \(index + 1)/\(files.count): \(rows.count) pages, \(articleCount) source article spans")
        }
        if let path = ProcessInfo.processInfo.environment["LIBRONX_OEB_FIND_RECEIPT"] {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_OEB_FIND_CORPUS"] != nil))
    func originalFindNavigatesFromCoverAndSelectsTheExactVisibleWord() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_OEB_FIND_CORPUS"]))
        let url = root.appendingPathComponent("Help-Addin-AudioBible-en.lbxoeb")
        let resource = LibraryResource(location: url, title: "Original Audio Bible Help", byteCount: 0,
            format: .libronixOEB, support: .opaqueContainer, provenance: .libronixMetadata)
        let reader = ReaderSession(resource: resource)
        let coordinator = ReaderOEBView.Coordinator(reader: reader, activate: {})
        let view = ReaderOEBView.makeWebView(reader: reader, coordinator: coordinator)
        view.setFrameSize(NSSize(width: 760, height: 900))
        defer {
            view.stopLoading(); view.navigationDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: "reader", contentWorld: .defaultClient)
            reader.cancel()
        }
        func renderCurrentPage() async throws {
            coordinator.begin(try #require(reader.page?.oeb), in: view)
            let end = Date().addingTimeInterval(10)
            while !coordinator.ready && Date() < end { try await Task.sleep(for: .milliseconds(10)) }
            try #require(coordinator.ready && reader.error == nil)
        }
        reader.load(.init(ordinal: 0))
        while reader.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        try await renderCurrentPage()
        reader.findQuery = "recordings"; reader.find(.forward)
        let end = Date().addingTimeInterval(10)
        while reader.page?.destination.ordinal == 0 && reader.findStatus == .searching && Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reader.page?.destination.ordinal == 1 && reader.history.map(\.ordinal) == [0])
        try await renderCurrentPage()
        #expect(reader.findStatus == .found(wrapped: false) && reader.selectedText == "recordings")
        #expect(reader.history.map(\.ordinal) == [0,1])
        _ = try await view.callAsyncJavaScript("return window.libronxReader.select(start,length);", arguments: ["start":reader.selectedRange.location,"length":reader.selectedRange.length], in: nil, contentWorld: .defaultClient)
        let selected = try await view.callAsyncJavaScript("return getSelection().toString();", in: nil, contentWorld: .defaultClient) as? String
        #expect(selected == "recordings")
        reader.findQuery = "Addin"; reader.find(.backward)
        let backwardEnd = Date().addingTimeInterval(10)
        while reader.findStatus == .searching && Date() < backwardEnd { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reader.selectedText == "Addin" && reader.history.map(\.ordinal) == [0,1])
        print("Original OEB native Find: cover -> Overview, selected recordings, history committed only after actual DOM agreement; backward Addin selected in place")
    }
}
