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
        let view = DictionaryWebView(frame: .zero, configuration: config)
        view.reader = reader
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
        if coordinator.ready {
            view.callAsyncJavaScript("let s=document.getElementById('libron-font-override'); if(!s){s=document.createElement('style');s.id='libron-font-override';document.head.appendChild(s);} s.textContent=font ? 'body,body *{font-family:'+JSON.stringify(font)+' !important}' : '';",
                arguments: ["font": AppPreferences.shared.readingFont], in: nil, in: .defaultClient) { _ in }
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
                    expectedContentLength: data.count, textEncodingName: LibronixOEBBook.mimeType(path) == "text/html" || LibronixOEBBook.mimeType(path) == "text/css" ? "utf-8" : nil))
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
                    self.selectionRequest = reader.selectionRequest
                    let range = reader.selectedRange
                    if range.length > 0 {
                        // Readiness is coordinator state, not observed SwiftUI state.
                        // Deliver a pending search/find range after DOM validation;
                        // a representable update can otherwise run before ready.
                        webView.callAsyncJavaScript("return window.libronxReader.select(start, length);",
                            arguments: ["start": range.location, "length": range.length],
                            in: nil, in: .defaultClient) { _ in }
                    }
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
          // Coordinates use the same visible text-node stream as selection.
          // Keep raw destinations; Swift accepts only recognized Bible syntax.
          const byElement = new Map(); let offset = 0;
          for (const node of visible) {
            for (let element = node.parentElement; element; element = element.parentElement) {
              const targets = [];
              if (element.hasAttribute('lbxrt:xref')) targets.push(element.getAttribute('lbxrt:xref'));
              if (element.tagName === 'A' && element.hasAttribute('href')) targets.push(element.getAttribute('href'));
              if (!targets.length || !node.length) continue;
              let records = byElement.get(element);
              if (!records) {
                records = [...new Set(targets)].map(target => ({start: offset, length: 0, target}));
                byElement.set(element, records);
              }
              for (const record of records) record.length = offset + node.length - record.start;
            }
            offset += node.length;
          }
          // Keep block/BR word boundaries without inserting display characters.
          const lexical = new Set(), nodeOffsets = []; let position = 0, priorBlock = null;
          function blockOwner(node) {
            for (let e = node.parentElement; e; e = e.parentElement) {
              if (['block','flow-root','flex','grid','list-item','table','table-cell','table-row','table-caption','table-row-group','table-header-group','table-footer-group'].includes(getComputedStyle(e).display)) return e;
            }
            return null;
          }
          for (const node of visible) {
            nodeOffsets.push(position);
            if (node.length) {
              const block = blockOwner(node);
              if (position > 0 && priorBlock !== block) lexical.add(position);
              priorBlock = block;
            }
            position += node.length;
          }
          for (const br of document.querySelectorAll('br')) {
            let shown = true;
            for (let e = br; e; e = e.parentElement) {
              const style = getComputedStyle(e);
              if (style.display === 'none' || style.visibility === 'hidden') { shown = false; break; }
            }
            if (!shown) continue;
            let low = 0, high = visible.length;
            while (low < high) {
              const mid = (low + high) >>> 1;
              if (br.compareDocumentPosition(visible[mid]) & Node.DOCUMENT_POSITION_FOLLOWING) high = mid;
              else low = mid + 1;
            }
            if (low < nodeOffsets.length && nodeOffsets[low] > 0) lexical.add(nodeOffsets[low]);
          }
          if (lexical.size > 100000) throw new Error('Too many source word boundaries');
          const links = Array.from(byElement.values()).flat();
          if (links.length > 100000) throw new Error('Too many source links');
          // Semantic fields share the existing visible-node coordinates. No
          // CSS class, font size or generated navigation label establishes one.
          const fields = {body: [], title: [], heading: [], footnote: [], quote: []};
          let fieldCount = 0, fieldLimit = false, fieldOffset = 0;
          function addField(kind, start, length) {
            if (!length || fieldLimit) return;
            const records = fields[kind], last = records[records.length - 1];
            if (last && last.location + last.length === start) last.length += length;
            else {
              if (++fieldCount > 100000) { fieldLimit = true; return; }
              records.push({location: start, length});
            }
          }
          for (const node of visible) {
            let note = false, heading = false, title = false, quotation = false, endnote = false;
            for (let element = node.parentElement; element; element = element.parentElement) {
              const types = (element.getAttribute('epub:type') || '').trim().split(/\s+/);
              const role = (element.getAttribute('role') || '').trim().split(/\s+/)[0];
              note ||= types.includes('footnote') || role === 'doc-footnote';
              endnote ||= types.includes('endnote') || types.includes('endnotes') || role === 'doc-endnote' || role === 'doc-endnotes';
              heading ||= /^H[1-6]$/.test(element.tagName) || role === 'heading';
              title ||= types.some(t => ['title','fulltitle','covertitle','halftitle','subtitle'].includes(t));
              quotation ||= element.tagName === 'Q' || element.tagName === 'BLOCKQUOTE';
            }
            if (note) addField('footnote', fieldOffset, node.length);
            if (heading) addField('heading', fieldOffset, node.length);
            if (title) addField('title', fieldOffset, node.length);
            if (quotation) addField('quote', fieldOffset, node.length);
            if (!note && !endnote && !heading && !title) addField('body', fieldOffset, node.length);
            fieldOffset += node.length;
          }
          // Field exhaustion cannot break established unqualified reading/find.
          return {text: visible.map(n => n.data).join(''), anchors, links, lexicalBreaks: [...lexical].sort((a,b) => a-b), fields: fieldLimit ? null : fields,
            fieldValues: {title: fields.title.length ? [] : (document.title ? [document.title] : [])}};
        },
        select: (start, length) => {
          if (!length) return false;
          const range = document.createRange(); let offset = 0, a = false, b = false;
          for (const node of nodes()) {
            if (!a && start < offset + node.length) { range.setStart(node, Math.max(0, start - offset)); a = true; }
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

/// Append the owned lookup action while retaining WebKit's native editing menu.
@MainActor final class DictionaryWebView: WKWebView {
    weak var reader: ReaderSession?
    private var pressureMonitor: Any?
    private var pressureActive = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let pressureMonitor { NSEvent.removeMonitor(pressureMonitor); self.pressureMonitor = nil }
        guard window != nil else { return }
        pressureMonitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.window === event.window,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return false }
                if event.stage < 2 { self.pressureActive = false }
                if event.stage >= 2, !self.pressureActive { self.pressureActive = true; self.quickLook(with: event) }
                return true
            }
            return handled ? nil : event
        }
    }
    override func quickLook(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let y = isFlipped ? point.y : bounds.height - point.y
        let original = url
        callAsyncJavaScript("""
        const range = document.caretRangeFromPoint(x, y);
        if (!range) return null;
        const selection = window.getSelection();
        selection.removeAllRanges(); selection.addRange(range);
        selection.modify('move', 'backward', 'word'); selection.modify('extend', 'forward', 'word');
        const box = selection.getRangeAt(0).getBoundingClientRect();
        return {word: selection.toString(), x: box.x, y: box.y, width: box.width, height: box.height};
        """, arguments: ["x": point.x, "y": y], in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.url == original, case let .success(value) = result,
                  let data = value as? [String: Any], let text = data["word"] as? String,
                  let word = DictionaryController.singleWord(text), let x = data["x"] as? Double,
                  let top = data["y"] as? Double, let width = data["width"] as? Double, let height = data["height"] as? Double else { return }
            let rect = NSRect(x: x, y: self.isFlipped ? top : self.bounds.height - top - height, width: width, height: height)
            self.reader?.onQuickDictionaryLookup?(word, self, rect)
        }
    }
    override func quickLookPreviewItems(_ sender: Any?) { lookupSelectedWord() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(title: L("Buscar en diccionario"), action: #selector(lookupSelectedWord), keyEquivalent: "")
        item.target = self; item.isEnabled = selectedWord != nil
        menu.addItem(.separator()); menu.addItem(item)
        FeatureHelp.shared.addItem(to: menu, topic: reader?.isDictionary == true ? .dictionary : .navigation)
        return menu
    }
    private var selectedWord: String? {
        guard let reader, let text = reader.page?.text, let range = Range(reader.selectedRange, in: text) else { return nil }
        return DictionaryController.singleWord(String(text[range]))
    }
    @objc private func lookupSelectedWord() {
        if let word = selectedWord { reader?.onQuickDictionaryLookup?(word, self, visibleRect.insetBy(dx: 40, dy: 40)) }
    }
}
