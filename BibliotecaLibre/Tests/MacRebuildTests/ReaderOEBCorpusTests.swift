import AppKit
import WebKit
import Testing
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct ReaderOEBCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_OEB_RENDER_CORPUS"] != nil))
    func originalHTMLStylesImagesSelectionFindAndOutputs() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_OEB_RENDER_CORPUS"]))
        let url = root.appendingPathComponent("Help-Addin-AudioBible-en.lbxoeb")
        let resource = LibraryResource(location: url, title: "Original Audio Bible Help", byteCount: 0,
            format: .libronixOEB, support: .opaqueContainer, provenance: .libronixMetadata, isHelp: true)
        let reader = ReaderSession(resource: resource)
        reader.page = try await ReaderSession.read(resource, .init(ordinal: 0))
        let coordinator = ReaderOEBView.Coordinator(reader: reader, activate: {})
        let view = ReaderOEBView.makeWebView(reader: reader, coordinator: coordinator)
        view.setFrameSize(NSSize(width: 760, height: 900))
        defer {
            view.stopLoading(); view.navigationDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: "reader", contentWorld: .defaultClient)
            reader.cancel()
        }
        func load(_ page: ReaderOEBPage) async throws {
            coordinator.begin(page, in: view)
            let deadline = Date().addingTimeInterval(20)
            while !coordinator.ready && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(reader.error == nil, "\(reader.error ?? "")")
            try #require(coordinator.ready, "Native WebKit did not commit the original OEB document")
        }
        let title = try #require(reader.page?.oeb)
        try await load(title)
        let imageState = try await view.callAsyncJavaScript("return Array.from(document.images).map(i=>({loaded:i.complete && i.naturalWidth>0, width:i.naturalWidth}));", in: nil, contentWorld: .defaultClient)
        let images = try #require(imageState as? [[String: Any]])
        #expect(images.count == 2 && images.allSatisfy { $0["loaded"] as? Bool == true })
        let output = try await ReaderOEBOutput.document(view, page: title, selectionOnly: false)
        let html = try #require(String(data: output.html, encoding: .utf8))
        #expect(html.contains("data:image/bmp;base64,"))
        #expect(html.contains("text-align: center"))
        #expect(output.text.contains("Audio Bible Addin Help"))
        if let receipt = ProcessInfo.processInfo.environment["LIBRONX_OEB_RENDER_RECEIPT"] {
            let folder = URL(fileURLWithPath: receipt, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try output.html.write(to: folder.appendingPathComponent("audio-title.html"), options: .atomic)
            try await ReaderOEBOutput.write(reader, type: "pdf", url: folder.appendingPathComponent("audio-title.pdf"))
            try await ReaderOEBOutput.write(reader, type: "webarchive", url: folder.appendingPathComponent("audio-title.webarchive"))
            let image = try await view.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: folder.appendingPathComponent("native-oeb-title-render.png"), options: .atomic)
            }
        }
        reader.page = try await ReaderSession.read(resource, .init(ordinal: 1))
        let overview = try #require(reader.page?.oeb)
        try await load(overview)
        let text = try #require(reader.page?.text)
        #expect(text.contains("The Audio Bible Addin"))
        #expect(!text.contains("OverviewOverview"))
        let style = try await view.callAsyncJavaScript("const h=document.querySelector('h1:not([style])'), d=document.querySelector('.DropCap'); return {size:getComputedStyle(h).fontSize, transform:getComputedStyle(h).textTransform, drop:getComputedStyle(d).fontSize, float:getComputedStyle(d).cssFloat, scripts:document.querySelectorAll('script').length};", in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(style?["transform"] as? String == "uppercase")
        #expect(style?["float"] as? String == "left")
        #expect(Double((style?["drop"] as? String ?? "").replacingOccurrences(of: "px", with: "")) ?? 0 > 40)
        reader.findQuery = "recordings"; reader.find(.forward)
        let findDeadline = Date().addingTimeInterval(10)
        while reader.findStatus == .searching && Date() < findDeadline { try await Task.sleep(for: .milliseconds(10)) }
        guard case .found = reader.findStatus else { Issue.record("OEB page Find failed"); return }
        let range = reader.selectedRange
        _ = try await view.callAsyncJavaScript("return window.libronxReader.select(start,length);", arguments: ["start":range.location,"length":range.length], in: nil, contentWorld: .defaultClient)
        let selected = try await view.callAsyncJavaScript("return getSelection().toString();", in: nil, contentWorld: .defaultClient) as? String
        #expect(selected == "recordings")
        let selectionOutput = try await ReaderOEBOutput.document(view, page: overview, selectionOnly: true)
        #expect(selectionOutput.text == "recordings")
        let link = try await view.callAsyncJavaScript("return document.querySelector('a').href;", in: nil, contentWorld: .defaultClient) as? String
        let linkString = try #require(link)
        let linkURL = try #require(URL(string: linkString))
        #expect(overview.book.article(for: linkURL)?.ordinal == 2)
        let restored = ReaderSession(resource: resource)
        restored.load(reader.page!.destination, selection: range, expectedFingerprint: LibrarySearchService.textFingerprint(text))
        while restored.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(restored.error == nil && restored.selectedRange.length == 0)
        try restored.acceptOEBProjection(text, at: try #require(restored.page?.oeb?.url))
        #expect(restored.selectedRange == range && restored.selectedText == "recordings")
        restored.load(reader.page!.destination, selection: range, expectedFingerprint: "stale")
        while restored.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(throws: LibronixBookError.sourceChanged) { try restored.acceptOEBProjection(text, at: restored.page!.oeb!.url) }
        #expect(restored.selectedRange.length == 0)
        restored.cancel()
        if let receipt = ProcessInfo.processInfo.environment["LIBRONX_OEB_RENDER_RECEIPT"] {
            let snapshot = WKSnapshotConfiguration()
            snapshot.rect = NSRect(x: 0, y: 0, width: 760, height: 260)
            let image = try await view.takeSnapshot(configuration: snapshot)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: receipt).appendingPathComponent("native-oeb-overview-render.png"), options: .atomic)
            }
        }
        print("Native OEB WebKit proof: original CSS, 2 BMP images, drop cap, visible DOM text, exact UTF-16 selection, Find, standalone HTML, PDF and web archive")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_OEB_RENDER_MEDIA"] != nil))
    func renderEveryOriginalHTMLPageWithItsOwnStylesAndImages() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_OEB_RENDER_MEDIA"]))
        let sources = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "lbxoeb" }.sorted { $0.path < $1.path }
        let resource = LibraryResource(location: try #require(sources.first), title: "OEB corpus renderer", byteCount: 0,
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
        var receipts: [[String: Any]] = []
        let service = LibronixOEBService()
        for (sourceIndex, source) in sources.enumerated() {
            let book = try await service.prepare(source)
            for path in book.members.keys.filter({ LibronixOEBBook.mimeType($0) == "text/html" }).sorted() {
                let page = ReaderOEBPage(book: book, url: book.url(path: path))
                reader.page = .init(destination: .init(ordinal: 0), text: "", sectionCount: book.directory.articles.count, oeb: page)
                reader.error = nil; coordinator.begin(page, in: view)
                let deadline = Date().addingTimeInterval(10)
                while !coordinator.ready && reader.error == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
                try #require(coordinator.ready, "OEB did not render: \(source.lastPathComponent)/\(path): \(reader.error ?? "timeout")")
                let value = try await view.callAsyncJavaScript("return {images:document.images.length, broken:Array.from(document.images).filter(i=>!i.complete || !i.naturalWidth).map(i=>i.getAttribute('src')), sheets:document.styleSheets.length, links:document.querySelectorAll('link[rel=stylesheet]').length, tables:document.querySelectorAll('table').length};", in: nil, contentWorld: .defaultClient)
                let state = try #require(value as? [String: Any])
                let broken = state["broken"] as? [String] ?? []
                let sheets = state["sheets"] as? Int ?? 0, links = state["links"] as? Int ?? 0
                #expect(broken.isEmpty && coordinator.assetFailures.isEmpty && sheets >= links,
                    "OEB missing presentation assets: \(source.lastPathComponent)/\(path), images=\(broken), files=\(coordinator.assetFailures)")
                receipts.append(["resource": source.path.replacingOccurrences(of: root.path + "/", with: ""), "page": path,
                    "images": state["images"] ?? 0, "brokenImages": broken, "styleSheets": sheets, "linkedStyleSheets": links,
                    "tables": state["tables"] ?? 0, "textUTF16": reader.page?.text.utf16.count ?? 0,
                    "assetFailures": coordinator.assetFailures, "passed": broken.isEmpty && coordinator.assetFailures.isEmpty && sheets >= links])
            }
            print("OEB native corpus \(sourceIndex + 1)/\(sources.count): \(receipts.count) pages")
        }
        if let output = ProcessInfo.processInfo.environment["LIBRONX_OEB_RENDER_RECEIPT"] {
            try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys]).write(
                to: URL(fileURLWithPath: output).appendingPathComponent("native-render-corpus.json"), options: .atomic)
        }
    }

    @Test func policyPreservesDoctypeMarkupAndOriginalStyles() throws {
        let source = "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\"><HTML><HEAD><LINK href=\"Help.css\" rel=stylesheet></HEAD><BODY><H1>Owned</H1><TABLE><TR><TD>α</TD></TR></TABLE></BODY></HTML>"
        let protected = try #require(String(data: ReaderOEBHTML.protectedHTML(Data(source.utf8)), encoding: .utf8))
        #expect(protected.hasPrefix("<!DOCTYPE HTML PUBLIC"))
        #expect(protected.replacingOccurrences(of: "<meta http-equiv=\"Content-Security-Policy\" content=\"\(ReaderOEBHTML.policy)\">", with: "") == source)
        #expect(ReaderOEBHTML.policy.contains("default-src 'none'"))
        #expect(throws: LibronixBookError.unsupportedArchive) { try ReaderOEBHTML.protectedHTML(Data([0xff,0xfe])) }
    }
}
