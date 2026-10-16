import AppKit
import SwiftUI
import WebKit
import LibronixCore

struct ReaderOEBPage: Sendable {
    let id = UUID()
    let book: LibronixOEBBook
    let url: URL
}

/// Uses the original HTML/CSS layout. Resource scripts are disabled; our own
/// isolated-world bridge only projects visible DOM text and maps selections.
struct ReaderOEBView: NSViewRepresentable {
    let reader: ReaderSession
    let page: ReaderOEBPage
    let activate: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(reader: reader, activate: activate) }
    func makeNSView(context: Context) -> WKWebView {
        Self.makeWebView(reader: reader, coordinator: context.coordinator)
    }
    static func makeWebView(reader: ReaderSession, coordinator: Coordinator) -> WKWebView {
        let config = configuration(source: coordinator, selectionHandler: coordinator)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = coordinator
        view.appearance = NSAppearance(named: .aqua)
        reader.oebWebView = view
        return view
    }
    static func configuration(source: any WKURLSchemeHandler, selectionHandler: (any WKScriptMessageHandler)? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(source, forURLScheme: "libronx-oeb")
        if let selectionHandler { config.userContentController.add(selectionHandler, contentWorld: .defaultClient, name: "reader") }
        config.userContentController.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient))
        return config
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.activate = activate
        view.pageZoom = reader.renderingScale
        if coordinator.pageID != page.id {
            coordinator.begin(page, in: view)
        }
        if coordinator.ready, coordinator.selectionRequest != reader.selectionRequest {
            coordinator.selectionRequest = reader.selectionRequest
            let range = reader.selectedRange
            view.callAsyncJavaScript("return window.libronxReader.select(start, length);",
                arguments: ["start": range.location, "length": range.length], in: nil, in: .defaultClient) { _ in }
        }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "reader", contentWorld: .defaultClient)
        if coordinator.reader?.oebWebView === view { coordinator.reader?.oebWebView = nil }
    }
    @MainActor final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKScriptMessageHandler {
        weak var reader: ReaderSession?
        var activate: () -> Void
        var book: LibronixOEBBook?
        var url: URL?
        var pageID: UUID?
        var ready = false
        var selectionRequest = -1
        var assetFailures: [String] = []
        private var navigation: WKNavigation?
        init(reader: ReaderSession, activate: @escaping () -> Void) { self.reader = reader; self.activate = activate }
        func begin(_ page: ReaderOEBPage, in view: WKWebView) {
            pageID = page.id; book = page.book; url = page.url
            ready = false; assetFailures = []; selectionRequest = -1
            navigation = view.load(URLRequest(url: page.url))
        }
        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            do {
                guard let book, let url = urlSchemeTask.request.url, let path = book.path(for: url),
                      let original = book.members[path] else { throw LibronixBookError.entryNotFound }
                try book.verifySource()
                var data = original
                if LibronixOEBBook.mimeType(path) == "text/html" {
                    data = try ReaderOEBHTML.protectedHTML(original)
                }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: LibronixOEBBook.mimeType(path),
                    expectedContentLength: data.count, textEncodingName: path.lowercased().hasSuffix(".html") || path.lowercased().hasSuffix(".css") ? "utf-8" : nil))
                urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch {
                assetFailures.append(urlSchemeTask.request.url?.lastPathComponent ?? "Recurso")
                urlSchemeTask.didFailWithError(error)
            }
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url, let book else { decisionHandler(.cancel); return }
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel); activate()
                if let article = book.article(for: target) {
                    reader?.load(.init(ordinal: article.ordinal, reference: target.fragment?.removingPercentEncoding), propagateReference: false)
                } else if ["https", "http", "mailto"].contains(target.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(target)
                } else { reader?.error = "Este enlace no tiene todavía una acción compatible en Mac." }
                return
            }
            decisionHandler(target == url && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation, webView.url == url else { return }
            let loadedID = pageID
            let fragment = url?.fragment?.removingPercentEncoding ?? ""
            webView.callAsyncJavaScript("return window.libronxReader.index(fragments);", arguments: ["fragments":fragment.isEmpty ? [] : [fragment]], in: nil, in: .defaultClient) { [weak self, weak webView] result in
                guard let self, let reader = self.reader, let webView, webView.url == self.url,
                      reader.page?.oeb?.url == self.url, self.pageID == loadedID,
                      reader.page?.oeb?.id == loadedID else { return }
                switch result {
                case .success(let value):
                    guard let index = value as? [String: Any], let text = index["text"] as? String else { return }
                    let anchors = index["anchors"] as? [String: Int]
                    do { try reader.acceptOEBProjection(text, at: self.url!, initialOffset: anchors?[fragment]) }
                    catch { reader.rejectOEBProjection(error, pageID: loadedID) }
                    self.ready = true
                    reader.presentationWarnings = self.assetFailures.isEmpty ? [] : ["No se pudieron cargar estos archivos de la página: " + self.assetFailures.joined(separator: ", ")]
                    // Fragment navigation is native WebKit; do not replace it
                    // with an initial empty selection at the top of the page.
                    self.selectionRequest = reader.selectedRange.length > 0 ? -1 : reader.selectionRequest
                case .failure(let error): reader.rejectOEBProjection(error, pageID: loadedID)
                }
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard navigation === self.navigation else { return }
            if (error as NSError).code != NSURLErrorCancelled { reader?.rejectOEBProjection(error, pageID: pageID) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard navigation === self.navigation else { return }
            if (error as NSError).code != NSURLErrorCancelled { reader?.rejectOEBProjection(error, pageID: pageID) }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let values = message.body as? [String: Any],
                  let origin = values["url"] as? String, origin == url?.absoluteString,
                  reader?.page?.oeb?.url == url, let start = values["start"] as? Int, let length = values["length"] as? Int,
                  start >= 0, length >= 0, let reader, let text = reader.page?.text,
                  start <= text.utf16.count, length <= text.utf16.count - start else { return }
            if reader.selectedRange != NSRange(location: start, length: length) {
                reader.selectedRange = NSRange(location: start, length: length)
            }
            if values["activate"] as? Bool == true { activate() }
        }
    }
    static let bridge = #"""
    (() => {
      function nodes() {
        const result = [], walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let node;
        while (node = walker.nextNode()) {
          let element = node.parentElement, visible = true;
          while (element) {
            const s = getComputedStyle(element);
            if (['SCRIPT','STYLE','NOSCRIPT','TEMPLATE'].includes(element.tagName) || s.display === 'none' || s.visibility === 'hidden') { visible = false; break; }
            element = element.parentElement;
          }
          if (visible) result.push(node);
        }
        return result;
      }
      function report(activate = false) {
        if (!window.webkit?.messageHandlers?.reader) return;
        const selection = getSelection(); let start = 0, end = 0, offset = 0, begun = false;
        if (selection.rangeCount) {
          const range = selection.getRangeAt(0);
          for (const node of nodes()) {
            if (range.intersectsNode(node)) {
              const a = range.startContainer === node ? range.startOffset : 0;
              const b = range.endContainer === node ? range.endOffset : node.length;
              if (!begun) { start = offset + a; begun = true; }
              end = offset + b;
            }
            offset += node.length;
          }
        }
        webkit.messageHandlers.reader.postMessage({url: location.href, start, length: Math.max(0, end - start), activate});
      }
      window.libronxReader = {
        projection: () => nodes().map(n => n.data).join(''),
        index: (fragments) => {
          const visible = nodes(), anchors = {};
          for (const fragment of fragments) {
            const target = document.getElementById(fragment) || document.getElementsByName(fragment)[0];
            if (!target) continue;
            let offset = 0;
            for (const node of visible) {
              if (target.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING) break;
              offset += node.length;
            }
            anchors[fragment] = offset;
          }
          return {text: visible.map(n => n.data).join(''), anchors};
        },
        select: (start, length) => {
          if (!length) return false;
          const range = document.createRange(); let offset = 0, a = false, b = false;
          for (const node of nodes()) {
            if (!a && start <= offset + node.length) { range.setStart(node, Math.max(0, start - offset)); a = true; }
            if (a && start + length <= offset + node.length) { range.setEnd(node, start + length - offset); b = true; break; }
            offset += node.length;
          }
          if (!a || !b) return false;
          const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
          range.startContainer.parentElement.scrollIntoView({block:'center'}); return true;
        },
        output: (selectionOnly) => {
          const selection = getSelection(), div = document.createElement('div');
          if (selectionOnly && selection.rangeCount && !selection.isCollapsed) div.append(selection.getRangeAt(0).cloneContents());
          else div.innerHTML = document.body.innerHTML;
          return {html: div.innerHTML, text: selectionOnly ? selection.toString() : document.body.innerText,
            styles: Array.from(document.styleSheets).map(s => ({base: s.href || location.href, css: Array.from(s.cssRules).map(r => r.cssText).join('\n')}))};
        }
      };
      document.addEventListener('selectionchange', () => report());
      document.addEventListener('mousedown', () => report(true));
    })();
    """#
}

/// Insert only a load policy into the original head. Author styles and markup
/// remain intact, including the source document's doctype/quirks mode.
enum ReaderOEBHTML {
    static let policy = "default-src 'none'; img-src libronx-oeb: data:; style-src libronx-oeb: 'unsafe-inline'; font-src libronx-oeb: data:; base-uri 'none'; form-action 'none'; frame-src 'none'"
    static func protectedHTML(_ data: Data) throws -> Data {
        guard var html = String(data: data, encoding: .utf8),
              let head = html.range(of: #"<head\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) else { throw LibronixBookError.unsupportedArchive }
        html.insert(contentsOf: "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">", at: head.upperBound)
        return Data(html.utf8)
    }
}
