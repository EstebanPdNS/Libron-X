import AppKit
import WebKit
import LibronixCore

@MainActor enum ReaderOEBOutput {
    struct Document { let text: String; let html: Data }
    static func document(_ view: WKWebView, page: ReaderOEBPage, selectionOnly: Bool) async throws -> Document {
        try page.book.verifySource()
        let value = try await view.callAsyncJavaScript("return window.libronxReader.output(selectionOnly);",
            arguments: ["selectionOnly": selectionOnly], in: nil, contentWorld: .defaultClient)
        guard view.url == page.url, let object = value as? [String: Any], let text = object["text"] as? String,
              let body = object["html"] as? String, let styles = object["styles"] as? [[String: String]] else { throw LibronixBookError.sourceChanged }
        let css = styles.map { style in
            embedCSS(style["css"] ?? "", base: URL(string: style["base"] ?? "") ?? page.url, book: page.book)
        }.joined(separator: "\n")
        let bodyWithImages = embedImages(body, base: page.url, book: page.book)
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; base-uri 'none'; form-action 'none'\"><style>" + css.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive) + "</style></head><body>" + bodyWithImages + "</body></html>"
        try page.book.verifySource()
        return Document(text: text, html: Data(html.utf8))
    }
    static func dataURL(_ reference: String, base: URL, book: LibronixOEBBook) -> String? {
        guard let url = URL(string: reference.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL,
              let path = book.path(for: url), let data = book.members[path] else { return nil }
        return "data:" + LibronixOEBBook.mimeType(path) + ";base64," + data.base64EncodedString()
    }
    static func embedImages(_ html: String, base: URL, book: LibronixOEBBook) -> String {
        replace(html, pattern: #"\bsrc\s*=\s*"([^"]*)""#) { match, source in
            guard let range = Range(match.range(at: 1), in: source), let value = dataURL(String(source[range]), base: base, book: book) else { return nil }
            return "src=\"" + value + "\""
        }
    }
    static func embedCSS(_ css: String, base: URL, book: LibronixOEBBook) -> String {
        replace(css, pattern: #"url\(\s*["']?([^\s"')]+)["']?\s*\)"#) { match, source in
            guard let range = Range(match.range(at: 1), in: source), let value = dataURL(String(source[range]), base: base, book: book) else { return nil }
            return "url(\"" + value + "\")"
        }
    }
    private static func replace(_ source: String, pattern: String, transform: (NSTextCheckingResult, String) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return source }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            if let value = transform(match, source), let range = Range(match.range, in: result) { result.replaceSubrange(range, with: value) }
        }
        return result
    }
    static func copy(_ reader: ReaderSession, workspace: StudyWorkspace) {
        guard let page = reader.page?.oeb, let view = reader.oebWebView else { return }
        Task {
            do {
                let document = try await document(view, page: page, selectionOnly: reader.selectedRange.length > 0)
                let board = NSPasteboard.general; board.clearContents()
                board.setString(document.text, forType: .string); board.setData(document.html, forType: .html)
            } catch { workspace.error = error.localizedDescription }
        }
    }
    static func write(_ reader: ReaderSession, type: String, url: URL) async throws {
        guard let page = reader.page?.oeb, let view = reader.oebWebView else { throw LibronixBookError.sourceChanged }
        try page.book.verifySource()
        switch type {
        case "pdf":
            let data = try await view.pdf(configuration: WKPDFConfiguration())
            guard view.url == page.url else { throw LibronixBookError.sourceChanged }
            try page.book.verifySource()
            try data.write(to: url, options: .atomic)
        case "webarchive":
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                view.createWebArchiveData { result in continuation.resume(with: result) }
            }
            guard view.url == page.url else { throw LibronixBookError.sourceChanged }
            try page.book.verifySource()
            try data.write(to: url, options: .atomic)
        case "txt", "html":
            let output = try await document(view, page: page, selectionOnly: reader.selectedRange.length > 0)
            try (type == "txt" ? Data(output.text.utf8) : output.html).write(to: url, options: .atomic)
        default: throw PersonalStateError.invalid("Para conservar el formato OEB, exporta como HTML, archivo web o PDF.")
        }
    }
    static func printReader(_ reader: ReaderSession) {
        guard let view = reader.oebWebView else { return }
        let operation = view.printOperation(with: NSPrintInfo.shared.copy() as! NSPrintInfo)
        operation.showsPrintPanel = true; operation.showsProgressPanel = true; operation.run()
    }
}
