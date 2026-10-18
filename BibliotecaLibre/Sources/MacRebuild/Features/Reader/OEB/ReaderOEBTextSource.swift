import AppKit
import WebKit
import LibronixCore

struct ReaderOEBViewport: Sendable, Hashable {
    let width: Double
    let zoom: Double
    init(width: Double = 760, zoom: Double = 1) {
        self.width = width.isFinite && (1...8192).contains(width) ? width : 760
        self.zoom = zoom.isFinite && (0.5...4.5).contains(zoom) ? zoom : 1
    }
}
struct ReaderOEBTextPage: Sendable {
    let text: String
    let fingerprint: String
    let path: String
    let articleRanges: [Int: NSRange]
    let referenceLinks: [BibleReferenceSourceLink]
    var estimatedBytes: Int { text.utf16.count * 2 + articleRanges.count * 64 + path.utf16.count * 2 + referenceLinks.reduce(0) { $0 + $1.target.utf16.count * 2 + 48 } + 128 }

    init(text: String, anchors: [String: Int], path: String, articles: [LibronixOEBArticle],
         referenceLinks: [BibleReferenceSourceLink] = []) throws {
        let count = text.utf16.count
        let entries = articles.filter { $0.path.lowercased() == path.lowercased() }.sorted { $0.ordinal < $1.ordinal }
        guard !entries.isEmpty else { throw LibronixBookError.invalidDirectory }
        var starts: [Int] = []
        for (index, article) in entries.enumerated() {
            let start: Int
            if index == 0 { start = 0 }
            else {
                guard let position = anchors[article.fragment] else { throw LibronixBookError.invalidDirectory }
                start = position
            }
            guard (0...count).contains(start), start >= (starts.last ?? 0) else { throw LibronixBookError.invalidDirectory }
            starts.append(start)
        }
        var ranges: [Int: NSRange] = [:]
        for (index, article) in entries.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : count
            ranges[article.ordinal] = NSRange(location: starts[index], length: end - starts[index])
        }
        self.text = text; fingerprint = LibrarySearchService.textFingerprint(text)
        self.path = path; articleRanges = ranges; self.referenceLinks = referenceLinks
    }
}

/// Bounded, source-stamped DOM projections use precisely the reader's isolated
/// script, original CSS and viewport. They never strip HTML to guess positions.
actor ReaderOEBTextSource {
    static let shared = ReaderOEBTextSource()
    private struct Key: Hashable { let origin: String; let path: String; let viewport: ReaderOEBViewport }
    private struct Job { let id: UUID; let task: Task<ReaderOEBTextPage, Error> }
    private let slots = OEBProjectionSlots()
    private var inflight: [Key: Job] = [:]
    private var cache: [Key: ReaderOEBTextPage] = [:]
    private var order: [Key] = []
    private var cachedBytes = 0
    func read(book: LibronixOEBBook, path: String, viewport: ReaderOEBViewport) async throws -> ReaderOEBTextPage {
        try Task.checkCancellation(); try book.verifySource()
        let key = Key(origin: book.origin, path: path.lowercased(), viewport: viewport)
        if let result = cache[key] {
            order.removeAll { $0 == key }; order.append(key)
            return result
        }
        let job: Job
        if let existing = inflight[key] { job = existing }
        else {
            let task = Task { [slots] in
                await slots.acquire()
                do {
                    try book.verifySource()
                    let result = try await OEBProjectionRenderer.project(book: book, path: path, viewport: viewport)
                    await slots.release(); return result
                } catch { await slots.release(); throw error }
            }
            job = Job(id: UUID(), task: task); inflight[key] = job
        }
        let result: ReaderOEBTextPage
        do { result = try await job.task.value }
        catch {
            if inflight[key]?.id == job.id { inflight[key] = nil }
            throw error
        }
        if inflight[key]?.id == job.id { inflight[key] = nil }
        try Task.checkCancellation(); try book.verifySource()
        if cache[key] == nil {
            cache[key] = result; order.append(key); cachedBytes += result.estimatedBytes
            while order.count > 64 || cachedBytes > 32 * 1024 * 1024 {
                let old = order.removeFirst()
                if let removed = cache.removeValue(forKey: old) { cachedBytes -= removed.estimatedBytes }
            }
        }
        return result
    }
}
private actor OEBProjectionSlots {
    private var available = 2
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { available += 1 }
        else { waiting.removeFirst().resume() }
    }
}

@MainActor private final class OEBProjectionArchive: NSObject, WKURLSchemeHandler {
    var book: LibronixOEBBook?
    var failures: [String] = []
    init(book: LibronixOEBBook) { self.book = book }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        do {
            guard let book, let url = task.request.url, url.host == book.origin else { throw URLError(.cancelled) }
            guard let path = book.path(for: url), let original = book.members[path] else { throw LibronixBookError.entryNotFound }
            try book.verifySource()
            let mime = LibronixOEBBook.mimeType(path)
            let data = mime == "text/html" ? try ReaderOEBHTML.protectedHTML(original) : original
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                textEncodingName: mime == "text/html" || mime == "text/css" ? "utf-8" : nil))
            task.didReceive(data); task.didFinish()
        } catch {
            if (error as? URLError)?.code != .cancelled { failures.append(task.request.url?.lastPathComponent ?? "OEB") }
            task.didFailWithError(error)
        }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@MainActor private final class OEBProjectionRenderer: NSObject, WKNavigationDelegate {
    private let source: OEBProjectionArchive
    private var path: String
    private var url: URL
    private let view: WKWebView
    private var completion: CheckedContinuation<ReaderOEBTextPage, Error>?
    private var timeout: Task<Void, Never>?
    private var runID = UUID()
    private var navigation: WKNavigation?
    private static var idle: [OEBProjectionRenderer] = []
    private init(book: LibronixOEBBook, path: String, viewport: ReaderOEBViewport) {
        source = OEBProjectionArchive(book: book); self.path = path; url = book.url(path: path)
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: viewport.width, height: 900),
            configuration: ReaderOEBView.configuration(source: source))
        super.init()
        view.pageZoom = viewport.zoom; view.appearance = NSAppearance(named: .aqua); view.navigationDelegate = self
    }
    static func project(book: LibronixOEBBook, path: String, viewport: ReaderOEBViewport) async throws -> ReaderOEBTextPage {
        // Reuse at most two isolated views; the service limits active jobs too.
        // A fresh view/data store for every article made cold resource Find slow.
        let renderer = idle.popLast() ?? OEBProjectionRenderer(book: book, path: path, viewport: viewport)
        renderer.runID = UUID(); let run = renderer.runID
        renderer.source.book = book; renderer.source.failures = []
        renderer.path = path; renderer.url = book.url(path: path)
        renderer.view.setFrameSize(NSSize(width: viewport.width, height: 900))
        renderer.view.pageZoom = viewport.zoom; renderer.view.navigationDelegate = renderer
        defer {
            renderer.view.navigationDelegate = nil; renderer.view.stopLoading()
            renderer.navigation = nil; renderer.source.book = nil
            if idle.count < 2 { idle.append(renderer) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                renderer.completion = continuation
                renderer.timeout = Task { [weak renderer] in
                    do { try await Task.sleep(for: .seconds(15)) }
                    catch { return }
                    renderer?.finish(.failure(PersonalStateError.invalid("La página OEB tardó demasiado en cargar para la búsqueda.")), run: run)
                }
                renderer.navigation = renderer.view.load(URLRequest(url: renderer.url))
            }
        } onCancel: { Task { @MainActor in renderer.finish(.failure(CancellationError()), run: run) } }
    }
    private func finish(_ result: Result<ReaderOEBTextPage, Error>, run: UUID) {
        guard run == runID, let completion else { return }
        self.completion = nil; timeout?.cancel(); timeout = nil
        view.navigationDelegate = nil; view.stopLoading()
        completion.resume(with: result)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url == url && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === self.navigation { finish(.failure(error), run: runID) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === self.navigation { finish(.failure(error), run: runID) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation, let book = source.book else { return }
        let run = runID, path = path
        Task { [self] in
            do {
                guard source.failures.isEmpty else { throw PersonalStateError.invalid("No se pudieron cargar todos los estilos o archivos de la página OEB.") }
                let entries = book.directory.articles.filter { $0.path.lowercased() == path.lowercased() }
                let fragments = Array(Set(entries.map(\.fragment).filter { !$0.isEmpty }))
                let raw = try await view.callAsyncJavaScript("return window.libronxReader.index(fragments);", arguments: ["fragments":fragments], in: nil, contentWorld: .defaultClient)
                guard let value = raw as? [String: Any], let text = value["text"] as? String,
                      text.utf16.count <= 16 * 1024 * 1024, let anchors = value["anchors"] as? [String: Int],
                      fragments.allSatisfy({ anchors[$0] != nil }),
                      let rawLinks = value["links"] as? [[String: Any]], rawLinks.count <= 100_000 else { throw LibronixBookError.invalidDirectory }
                let links = try rawLinks.map { raw -> BibleReferenceSourceLink in
                    guard let start = raw["start"] as? Int, let length = raw["length"] as? Int,
                          let target = raw["target"] as? String, start >= 0, length > 0,
                          start <= text.utf16.count, length <= text.utf16.count - start,
                          Range(NSRange(location: start, length: length), in: text) != nil else { throw LibronixBookError.invalidDirectory }
                    return .init(range: .init(location: start, length: length), target: target)
                }
                let result = try ReaderOEBTextPage(text: text, anchors: anchors, path: path, articles: entries, referenceLinks: links)
                try book.verifySource(); finish(.success(result), run: run)
            } catch { finish(.failure(error), run: run) }
        }
    }
}
