import AppKit
import SwiftUI
import LibronixCore

/// One native scrolling document containing independently selectable source
/// articles. Each NSTextView keeps its own source UTF-16 coordinate system.
struct ReaderArticleFlowView: NSViewRepresentable {
    let reader: ReaderSession
    let workspace: StudyWorkspace
    // Explicit presentation values keep SwiftUI observation at the call site;
    // newly prefetched pages must update the native document without a click.
    let pages: [ReaderPage]
    let selectionRevision: Int
    let scale: Double
    let fontsRevision: Int
    let highlights: [ReaderHighlight]
    let visibleLines: Set<Int>?
    func makeCoordinator() -> Coordinator { Coordinator(reader: reader, workspace: workspace) }
    func makeNSView(context: Context) -> ReaderScrollView {
        let scroll = ReaderScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        scroll.contentView.drawsBackground = true; scroll.contentView.backgroundColor = .textBackgroundColor
        scroll.scrollerInsets = .init(top: 2, left: 0, bottom: 2, right: 4)
        let document = FlowDocument(); document.autoresizingMask = [.width]
        scroll.documentView = document
        let coordinator = context.coordinator
        coordinator.scroll = scroll; coordinator.document = document
        document.onWidthChange = { [weak coordinator] in coordinator?.layoutArticles() }
        scroll.activate = { workspace.activate(reader) }
        scroll.onUserScroll = { [weak coordinator] in coordinator?.userScrolled() }
        let scroller = ReaderScroller(); scroller.onUserScroll = scroll.onUserScroll
        scroll.verticalScroller = scroller
        return scroll
    }
    func updateNSView(_ scroll: ReaderScrollView, context: Context) {
        context.coordinator.update()
        if !reader.flowEnabled {
            Task { @MainActor [weak coordinator = context.coordinator] in
                guard let coordinator, !coordinator.isDismantled, coordinator.scroll != nil else { return }
                coordinator.reader.startReadingFlow()
            }
        }
    }
    static func dismantleNSView(_ scroll: ReaderScrollView, coordinator: Coordinator) {
        coordinator.isDismantled = true
        coordinator.observation?.cancel()
        for surface in coordinator.surfaces.values { surface.view.linkPreview.dismiss() }
        coordinator.reader.flowEnabled = false
        coordinator.reader.flowGeneration += 1; coordinator.reader.flowTask?.cancel(); coordinator.reader.flowTask = nil
        scroll.onUserScroll = nil
    }
    final class FlowDocument: NSView {
        var onWidthChange: (() -> Void)?
        override var isFlipped: Bool { true }
        override func setFrameSize(_ size: NSSize) {
            let changed = abs(size.width - frame.width) > 0.5
            super.setFrameSize(size)
            if changed { onWidthChange?() }
        }
    }
    @MainActor final class Surface {
        let view = ActiveTextView()
        let delegate = ReaderTextView.Coordinator()
        var page: ReaderPage
        var revision = ""
        var sourceStamp: LegacyGraphicSourceStamp?
        var graphicHashes: [String] = []
        var warnings: [String] = []
        init(page: ReaderPage) {
            self.page = page
            view.textContainer?.replaceLayoutManager(ReaderLayoutManager())
            view.isEditable = false; view.isSelectable = true; view.isRichText = true
            view.importsGraphics = false; view.isAutomaticLinkDetectionEnabled = false
            view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
            view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
            view.drawsBackground = false // One shared scroll background, including trailing blank space.
            view.textContainerInset = .init(width: 16, height: 8)
            view.isVerticallyResizable = true; view.isHorizontallyResizable = false
            view.textContainer?.widthTracksTextView = true
            view.textContainer?.containerSize = .init(width: 0, height: CGFloat.greatestFiniteMagnitude)
            view.delegate = delegate
        }
    }
    @MainActor final class Coordinator {
        let reader: ReaderSession
        let workspace: StudyWorkspace
        weak var scroll: ReaderScrollView?
        weak var document: FlowDocument?
        var surfaces: [Int: Surface] = [:]
        var order: [Int] = []
        var selectionRequest = -1
        var observation: Task<Void, Never>?
        var isLayingOut = false
        var layoutDirty = true
        var layoutSize = CGSize.zero
        var trailingPadding: CGFloat = 0
        var isDismantled = false
        init(reader: ReaderSession, workspace: StudyWorkspace) { self.reader = reader; self.workspace = workspace }
        func update() {
            guard !isDismantled, let document, let scroll else { return }
            let anchor = viewportAnchor()
            let pages = reader.readingFlowPages, ordinals = pages.map { $0.destination.ordinal }
            for id in Set(order).subtracting(ordinals) {
                layoutDirty = true
                surfaces[id]?.view.linkPreview.dismiss(); surfaces.removeValue(forKey: id)?.view.removeFromSuperview()
            }
            if order != ordinals { layoutDirty = true }
            order = ordinals
            for page in pages {
                let id = page.destination.ordinal
                let surface = surfaces[id] ?? Surface(page: page)
                if surfaces[id] == nil { surfaces[id] = surface; document.addSubview(surface.view) }
                surface.page = page
                surface.view.contextHelpTopic = reader.isDictionary ? .dictionary : (reader.canSynchronizeBible ? .bibleReading : .navigation)
                surface.view.activate = { [weak self] in guard let self else { return }; self.workspace.activate(self.reader) }
                surface.view.lookupWord = { [weak workspace] word in
                    guard let workspace else { return }; workspace.dictionary.show(word, workspace: workspace)
                }
                surface.view.quickLookupWord = { [weak workspace, weak reader] word, view, rect in
                    guard let workspace, let reader else { return }
                    workspace.activate(reader); workspace.dictionary.show(word, workspace: workspace, anchor: view, rect: rect)
                }
                surface.view.onKeyboardScroll = { [weak self] in self?.userScrolled() }
                surface.view.linkPreview.resource = reader.resource
                surface.view.linkPreview.resolveResource = { [weak workspace] source, link in
                    guard let workspace else { throw RebuildError.bibleReferenceTargetUnavailable }
                    return try workspace.resourceForInlineLink(link, source: source)
                }
                surface.view.linkPreview.onOpen = { [weak self] resource, destination, newReader in
                    guard let self else { return }
                    self.workspace.openInlineLink(resource, destination: destination, from: self.reader, newReader: newReader)
                }
                surface.delegate.onSelection = { [weak self, weak surface] range in
                    guard let self, let surface else { return }
                    self.reader.selectFlowPage(surface.page, selection: range)
                }
                render(surface)
            }
            layoutArticles()
            if selectionRequest != reader.selectionRequest, let current = reader.page,
               let surface = surfaces[current.destination.ordinal] {
                selectionRequest = reader.selectionRequest
                let range = reader.selectedRange
                if Range(range, in: surface.view.string) != nil {
                    surface.delegate.isApplying = true; surface.view.setSelectedRange(range); surface.delegate.isApplying = false
                    align(surface, offset: reader.viewportCharacterOffset ?? range.location)
                }
            } else if let anchor, let surface = surfaces[anchor.ordinal] {
                scroll.contentView.scroll(to: .init(x: 0, y: surface.view.frame.minY + anchor.localY))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            let warnings = surfaces[reader.page?.destination.ordinal ?? -1]?.warnings ?? []
            let combined = warnings + [reader.flowWarning].compactMap { $0 }
            if reader.presentationWarnings != combined {
                let destination = reader.page?.destination
                Task { @MainActor [weak self] in
                    guard let self, !self.isDismantled, self.scroll != nil, self.reader.page?.destination == destination else { return }
                    self.reader.presentationWarnings = combined
                }
            }
        }
        private func render(_ surface: Surface) {
            let page = surface.page, delegate = surface.delegate
            let marks = reader.highlights.filter { $0.ordinal == page.destination.ordinal }
            let revision = AppPreferences.shared.readingFont + ":" + String(reader.renderingScale) + ":" + String(reader.sourceFontsRevision) + ":" +
                String(describing: reader.visibleInterlinearLines) + ":" + String(describing: marks)
            let graphicHashes = page.graphics.map(\.sha256)
            guard delegate.text != page.text || delegate.identity != page.destination || surface.revision != revision ||
                  surface.sourceStamp != page.sourceStamp || surface.graphicHashes != graphicHashes || delegate.inlineLinks != page.inlineLinks else { return }
            layoutDirty = true
            delegate.isApplying = true
            defer { delegate.isApplying = false }
            let selected = surface.view.selectedRange()
            delegate.text = page.text; delegate.identity = page.destination; surface.revision = revision
            surface.sourceStamp = page.sourceStamp; surface.graphicHashes = graphicHashes; delegate.inlineLinks = page.inlineLinks
            let lines = reader.visibleInterlinearLines ?? (page.interlinearLines.isEmpty ? nil : Set(page.interlinearLines.filter(\.visibleByDefault).map(\.ordinal)))
            let rendered = ReaderTypography.render(text: page.text, content: page.content, typography: page.typography,
                scale: reader.renderingScale, visibleInterlinearLines: lines)
            let display = NSMutableAttributedString(attributedString: rendered.text)
            for (index, link) in page.inlineLinks.enumerated() where Range(link.range, in: page.text) != nil {
                display.addAttribute(.link, value: URL(string: "libronx-inline://local/\(index)")!, range: link.range)
            }
            let fingerprint = LibrarySearchService.textFingerprint(page.text)
            for mark in marks where mark.fingerprint == fingerprint && Range(mark.range, in: page.text) != nil {
                let color: NSColor = switch mark.color { case "green": .systemGreen; case "blue": .systemBlue; case "pink": .systemPink; default: .systemYellow }
                display.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.35), range: mark.range)
            }
            let images = ReaderImageRenderer.install(page.graphics, in: display)
            surface.warnings = rendered.warnings + images.warnings
            surface.view.sourceLinks = page.inlineLinks
            delegate.biblePositions = page.content?.anchors.compactMap { anchor in
                guard anchor.characterOffset >= 0, anchor.characterOffset < page.text.utf16.count,
                      anchor.reference.flatMap(LegacyPassageQuery.sourceReference) != nil else { return nil }
                return (source: anchor.characterOffset, visible: ActiveTextView.visibleCharacter(in: page.text as NSString, at: anchor.characterOffset))
            } ?? []
            surface.view.isReplacingDocument = true; surface.view.inlineImages = []
            surface.view.textStorage?.setAttributedString(display)
            surface.view.inlineImages = images.images; surface.view.isReplacingDocument = false
            if Range(selected, in: page.text) != nil { surface.view.setSelectedRange(selected) }
        }
        func layoutArticles() {
            guard !isLayingOut, let document, let scroll else { return }
            let contentSize = scroll.contentSize
            if !layoutDirty && abs(layoutSize.width - contentSize.width) <= 0.5 {
                if layoutSize.height != contentSize.height {
                    let extent = order.compactMap { surfaces[$0]?.view.frame.maxY }.max() ?? 0
                    document.setFrameSize(.init(width: contentSize.width, height: max(contentSize.height, extent + trailingPadding)))
                    layoutSize = contentSize
                    if extent - scroll.contentView.bounds.minY < contentSize.height * 1.5 {
                        Task { @MainActor [weak reader] in reader?.extendReadingFlowForViewport() }
                    }
                }
                return
            }
            isLayingOut = true
            defer { isLayingOut = false; layoutDirty = false; layoutSize = contentSize }
            let width = scroll.contentSize.width
            guard width > 1 else { return }
            var y: CGFloat = 0
            for id in order {
                guard let surface = surfaces[id], let layout = surface.view.layoutManager,
                      let container = surface.view.textContainer else { continue }
                let view = surface.view
                surface.delegate.isApplying = true
                if abs(view.frame.width - width) > 0.5 {
                    view.setFrameSize(.init(width: width, height: max(1, view.frame.height)))
                }
                let size = NSSize(width: max(1, width - view.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
                if container.containerSize != size { container.containerSize = size }
                view.fitImages(); layout.ensureLayout(for: container)
                let height = max(1, ceil(layout.usedRect(for: container).maxY + view.textContainerInset.height * 2))
                let frame = NSRect(x: 0, y: y, width: width, height: height)
                if view.frame != frame { view.frame = frame }
                surface.delegate.isApplying = false
                y += height
            }
            let size = NSSize(width: width, height: max(scroll.contentSize.height, y + trailingPadding))
            if document.frame.size != size { document.setFrameSize(size) }
            if y - scroll.contentView.bounds.minY < scroll.contentSize.height * 1.5 {
                Task { @MainActor [weak reader] in reader?.extendReadingFlowForViewport() }
            }
        }
        private func viewportAnchor() -> (ordinal: Int, localY: CGFloat)? {
            guard let scroll else { return nil }
            let y = scroll.contentView.bounds.minY
            guard let id = order.first(where: { surfaces[$0].map { $0.view.frame.maxY > y } == true }), let surface = surfaces[id] else { return nil }
            return (id, y - surface.view.frame.minY)
        }
        private func align(_ surface: Surface, offset: Int) {
            guard let scroll, let document, let layout = surface.view.layoutManager, let container = surface.view.textContainer,
                  !surface.view.string.isEmpty else { return }
            let view = surface.view
            let character = ActiveTextView.visibleCharacter(in: view.string as NSString, at: offset)
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: character)
            guard glyph < layout.numberOfGlyphs else { return }
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = surface.view.frame.minY + view.textContainerOrigin.y + line.minY
            let contentHeight = order.compactMap { surfaces[$0]?.view.frame.maxY }.max() ?? 0
            trailingPadding = max(0, y + scroll.contentSize.height - contentHeight)
            document.setFrameSize(.init(width: document.frame.width, height: max(scroll.contentSize.height, contentHeight + trailingPadding)))
            scroll.contentView.scroll(to: .init(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        func userScrolled() {
            guard observation == nil else { return }
            let generation = reader.flowGeneration
            observation = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                guard let self else { return }; self.observation = nil
                guard self.reader.flowGeneration == generation else { return }
                guard let anchor = self.viewportAnchor(), let surface = self.surfaces[anchor.ordinal],
                      let layout = surface.view.layoutManager, let container = surface.view.textContainer else { return }
                let view = surface.view
                let point = NSPoint(x: view.textContainerInset.width + container.lineFragmentPadding,
                    y: max(0, anchor.localY - view.textContainerOrigin.y + 2))
                let glyph = layout.glyphIndex(for: point, in: container)
                guard glyph < layout.numberOfGlyphs else { return }
                var lineRange = NSRange()
                _ = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
                let line = layout.characterRange(forGlyphRange: lineRange, actualGlyphRange: nil)
                let verse = surface.delegate.biblePositions.first { NSLocationInRange($0.visible, line) }
                self.reader.observeFlowPage(anchor.ordinal, offset: verse?.source ?? layout.characterIndexForGlyph(at: glyph))
            }
        }
    }
}
