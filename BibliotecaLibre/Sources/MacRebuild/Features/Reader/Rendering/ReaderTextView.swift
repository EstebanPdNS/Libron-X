import AppKit
import SwiftUI
import LibronixCore

/// A new native selectable text surface. Rich original layout is a separate acceptance gate.
struct ReaderTextView: NSViewRepresentable {
    let text: String
    let selection: NSRange?
    let identity: ReaderDestination?
    var selectionRequest = 0
    var content: LegacySectionContent? = nil
    var typography: LegacyTypography? = nil
    var graphics: [LegacyGraphicAsset] = []
    var scale = 1.0
    var highlights: [ReaderHighlight] = []
    var visibleInterlinearLines: Set<Int>? = nil
    var sourceFontsRevision = 0
    var onWarnings: ([String]) -> Void = { _ in }
    var onSelection: (NSRange) -> Void = { _ in }
    var onVisiblePosition: (Int) -> Void = { _ in }
    var viewportOffset: Int?
    var resource: LibraryResource? = nil
    var inlineLinks: [LegacyInlineLink] = []
    var onOpenLink: (LibraryResource, ReaderDestination, Bool) -> Void = { _, _, _ in }
    var resolveLinkResource: ((LibraryResource, LegacyInlineLink) throws -> LibraryResource)? = nil
    let activate: () -> Void
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var identity: ReaderDestination?; var text = ""; var scale = 0.0; var graphicHashes: [String] = []
        var selectionRequest = -1
        var highlights: [ReaderHighlight] = []
        var visibleInterlinearLines: Set<Int>?
        var sourceFontsRevision = -1
        var inlineLinks: [LegacyInlineLink] = []
        var isApplying = false
        var onSelection: (NSRange) -> Void = { _ in }
        var onVisiblePosition: (Int) -> Void = { _ in }
        var scrollTask: Task<Void, Never>?
        var biblePositions: [(source: Int, visible: Int)] = []
        func cancelViewportObservation() { scrollTask?.cancel(); scrollTask = nil }
        func userScrolled(_ scroll: NSScrollView) {
            // Leave native scrolling synchronous and untouched. At most one
            // pending observation samples the latest viewport, including during
            // a continuous gesture; do not create/cancel a task per wheel tick.
            guard !isApplying, !biblePositions.isEmpty, scrollTask == nil else { return }
            let expectedIdentity = identity, expectedText = text
            scrollTask = Task { @MainActor [weak self, weak scroll] in
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                self?.scrollTask = nil
                guard let self, let scroll, !self.isApplying, self.identity == expectedIdentity,
                      self.text == expectedText, let view = (scroll as? ReaderScrollView)?.readingTextView,
                      let layout = view.layoutManager, let container = view.textContainer,
                      layout.numberOfGlyphs > 0 else { return }
                let visible = scroll.documentVisibleRect
                let point = NSPoint(x: view.textContainerInset.width + container.lineFragmentPadding,
                                    y: max(0, visible.minY - view.textContainerOrigin.y + 2))
                let glyph = layout.glyphIndex(for: point, in: container)
                guard glyph < layout.numberOfGlyphs else { return }
                var lineGlyphs = NSRange()
                _ = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
                let line = layout.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
                let firstVerse = self.biblePositions.first { NSLocationInRange($0.visible, line) }
                self.onVisiblePosition(firstVerse?.source ?? layout.characterIndexForGlyph(at: glyph))
            }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplying, let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange(), expectedText = text, expectedIdentity = identity
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, !self.isApplying, self.text == expectedText,
                      self.identity == expectedIdentity, view.selectedRange() == range else { return }
                self.onSelection(range)
            }
        }
        func textView(_ textView: NSTextView, doubleClickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
            (textView as? ActiveTextView)?.openImage(at: charIndex)
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            (textView as? ActiveTextView)?.showSourceLink(at: charIndex)
            return true // Source strings are never dispatched as URL/command handlers.
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelViewportObservation()
        (scroll as? ReaderScrollView)?.readingTextView?.linkPreview.dismiss()
        (scroll as? ReaderScrollView)?.onUserScroll = nil
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ReaderScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 4)
        let view = ActiveTextView()
        view.textContainer?.replaceLayoutManager(ReaderLayoutManager())
        view.isEditable = false; view.isSelectable = true
        view.isRichText = true; view.importsGraphics = false
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.font = NSFont(name: "Times New Roman", size: 12) ?? .systemFont(ofSize: 12)
        view.delegate = context.coordinator
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 16, height: 16)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.activate = activate
        scroll.documentView = ReaderDocumentView(textView: view)
        scroll.onUserScroll = { [weak coordinator = context.coordinator, weak scroll] in
            if let scroll { coordinator?.userScrolled(scroll) }
        }
        view.onKeyboardScroll = scroll.onUserScroll
        let scroller = ReaderScroller()
        scroller.onUserScroll = scroll.onUserScroll
        scroll.verticalScroller = scroller
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = (scroll as? ReaderScrollView)?.readingTextView else { return }
        view.activate = activate
        (scroll as? ReaderScrollView)?.activate = activate
        let coordinator = context.coordinator
        view.linkPreview.resource = resource
        view.linkPreview.onOpen = onOpenLink
        view.linkPreview.resolveResource = resolveLinkResource
        coordinator.onSelection = onSelection
        coordinator.onVisiblePosition = onVisiblePosition
        let pageChanged = context.coordinator.text != text || context.coordinator.identity != identity
        let renderChanged = pageChanged || coordinator.scale != scale || coordinator.graphicHashes != graphics.map(\.sha256) || coordinator.highlights != highlights || coordinator.visibleInterlinearLines != visibleInterlinearLines || coordinator.sourceFontsRevision != sourceFontsRevision || coordinator.inlineLinks != inlineLinks
        let selectionChanged = coordinator.selectionRequest != selectionRequest
        guard renderChanged || selectionChanged else { return }
        coordinator.cancelViewportObservation()
        coordinator.isApplying = true
        defer { coordinator.isApplying = false }
        coordinator.selectionRequest = selectionRequest
        let previousSelection = view.selectedRange()
        let origin = scroll.contentView.bounds.origin
        if renderChanged {
        if pageChanged {
            view.linkPreview.dismiss()
            (view.superview as? ReaderDocumentView)?.bottomPadding = 0
        }
        context.coordinator.text = text; context.coordinator.identity = identity; context.coordinator.scale = scale
        context.coordinator.graphicHashes = graphics.map(\.sha256)
        coordinator.highlights = highlights
        coordinator.visibleInterlinearLines = visibleInterlinearLines
        coordinator.sourceFontsRevision = sourceFontsRevision
        coordinator.inlineLinks = inlineLinks
        view.sourceLinks = inlineLinks
        let rendered = ReaderTypography.render(text: text, content: content, typography: typography, scale: scale,
                                               visibleInterlinearLines: visibleInterlinearLines)
        let display = NSMutableAttributedString(attributedString: rendered.text)
        for (index, link) in inlineLinks.enumerated() where Range(link.range, in: text) != nil {
            if let url = URL(string: "libronx-inline://local/\(index)") {
                display.addAttribute(.link, value: url, range: link.range)
            }
        }
        let fingerprint = LibrarySearchService.textFingerprint(text)
        for mark in highlights where mark.ordinal == identity?.ordinal && mark.fingerprint == fingerprint && Range(mark.range, in: text) != nil {
            let color: NSColor = switch mark.color { case "green": .systemGreen; case "blue": .systemBlue; case "pink": .systemPink; default: .systemYellow }
            display.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.35), range: mark.range)
        }
        let installed = ReaderImageRenderer.install(graphics, in: display)
        let warnings = rendered.warnings.filter { graphics.isEmpty || $0 != "Las imágenes integradas todavía requieren representación." } + installed.warnings
        Task { @MainActor in
            guard context.coordinator.identity == identity, context.coordinator.text == text, context.coordinator.scale == scale else { return }
            onWarnings(warnings)
        }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.isReplacingDocument = true
        view.inlineImages = []
        view.textStorage?.beginEditing()
        view.textStorage?.setAttributedString(display)
        view.textStorage?.endEditing()
        coordinator.biblePositions = content?.anchors.compactMap { anchor in
            guard anchor.characterOffset >= 0, anchor.characterOffset < text.utf16.count,
                  let raw = anchor.reference, LegacyPassageQuery.sourceReference(raw) != nil else { return nil }
            return (source: anchor.characterOffset, visible: ActiveTextView.visibleCharacter(in: text as NSString, at: anchor.characterOffset))
        } ?? []
        view.inlineImages = installed.images
        view.isReplacingDocument = false
        view.fitImages()
        }
        if !pageChanged && !selectionChanged {
            view.setSelectedRange(previousSelection)
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        if let selection, selection.location >= 0, selection.length >= 0,
           selection.location <= view.string.utf16.count,
           selection.length <= view.string.utf16.count - selection.location {
            view.setSelectedRange(selection); view.alignCharacterToTop(selection.location, in: scroll)
        } else { view.setSelectedRange(NSRange(location: 0, length: 0)); view.scrollToBeginningOfDocument(nil) }
        if let viewportOffset, (0...view.string.utf16.count).contains(viewportOffset) {
            view.alignCharacterToTop(viewportOffset, in: scroll)
        }
    }
}
/// Only input events trigger viewport linking. Programmatic scrolling in a
/// receiving pane therefore cannot feed back into the originating reader.
/// The document owns the trailing reading space used by verse alignment.
/// The native text view retains its own layout/selection coordinate system.
final class ReaderDocumentView: NSView {
    let textView: ActiveTextView
    var bottomPadding: CGFloat = 0 { didSet { updateExtent() } }
    override var isFlipped: Bool { true }
    init(textView: ActiveTextView) {
        self.textView = textView
        super.init(frame: textView.frame)
        autoresizingMask = [.width]
        addSubview(textView)
    }
    required init?(coder: NSCoder) { nil }
    func updateExtent() {
        let height = max(0, textView.frame.height + bottomPadding)
        if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: frame.width, height: height)) }
    }
}

final class ReaderScrollView: NSScrollView {
    var readingTextView: ActiveTextView? {
        (documentView as? ReaderDocumentView)?.textView ?? documentView as? ActiveTextView
    }
    // AppKit may assign the preferred global style again when this view enters
    // a window. This reader explicitly uses the floating presentation requested
    // for the Mac workspace, without changing the system's scrollbar setting.
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
    // AppKit otherwise opts subclasses that override scrollWheel out of
    // responsive scrolling. We delegate the gesture unchanged to AppKit and
    // only schedule a later viewport observation, so this remains compatible.
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
    var activate: (() -> Void)?
    var onUserScroll: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        activate?(); super.scrollWheel(with: event); onUserScroll?()
    }
}
final class ReaderScroller: NSScroller {
    // The subclass only observes native input; it supports AppKit's floating
    // thumb. Without this opt-in AppKit can fall back to the legacy gray track.
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    var onUserScroll: (() -> Void)?
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event); onUserScroll?() }
}
final class ActiveTextView: NSTextView {
    let linkPreview = ReaderLinkPreviewController()
    var sourceLinks: [LegacyInlineLink] = []
    private var sourceTrackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        if let sourceTrackingArea { removeTrackingArea(sourceTrackingArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); sourceTrackingArea = area
        window?.acceptsMouseMovedEvents = true
    }
    override func mouseMoved(with event: NSEvent) {
        guard !isReplacingDocument, let layout = layoutManager, let container = textContainer,
              !sourceLinks.isEmpty else { linkPreview.cancelHover(); return }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x; point.y -= textContainerOrigin.y
        let glyph = layout.glyphIndex(for: point, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point),
              showSourceLink(at: layout.characterIndexForGlyph(at: glyph), hovering: true) else {
            linkPreview.cancelHover(); return
        }
    }
    override func mouseExited(with event: NSEvent) { linkPreview.cancelHover(); super.mouseExited(with: event) }
    @discardableResult func showSourceLink(at index: Int, hovering: Bool = false) -> Bool {
        guard let link = sourceLinks.first(where: { NSLocationInRange(index, $0.range) }),
              let layout = layoutManager, let container = textContainer else { return false }
        let glyphs = layout.glyphRange(forCharacterRange: link.range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
        linkPreview.show(link, at: rect, in: self, hovering: hovering)
        return true
    }
    static func visibleCharacter(in text: NSString, at offset: Int) -> Int {
        guard text.length > 0 else { return 0 }
        var position = min(max(0, offset), text.length - 1)
        while position + 1 < text.length, let scalar = UnicodeScalar(text.character(at: position)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.properties.generalCategory == .format {
            position += 1
        }
        return position
    }
    /// Synchronization positions the actual verse line at the top, including
    /// when that verse was already visible. A bottom inset permits the final
    /// verse of a short article to reach the same position in every edition.
    func alignCharacterToTop(_ offset: Int, in scroll: NSScrollView) {
        guard offset >= 0, offset <= string.utf16.count, !string.isEmpty,
              let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        // Original references can precede an invisible joiner/newline whose
        // glyph belongs to the preceding verse's line. Align the visible verse
        // number/body while retaining the original source anchor unchanged.
        let character = Self.visibleCharacter(in: string as NSString, at: offset)
        let glyph = layout.glyphIndexForCharacter(at: character)
        guard glyph < layout.numberOfGlyphs else { return }
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        scroll.automaticallyAdjustsContentInsets = false
        // Padding belongs to the document. A scroll-view content inset also
        // shortens the overlay scroller's track to a tiny region near the top.
        (superview as? ReaderDocumentView)?.bottomPadding = max(0, scroll.contentView.bounds.height - line.height - 16)
        let origin = NSPoint(x: scroll.contentView.bounds.minX, y: max(0, textContainerOrigin.y + line.minY))
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    struct InlineImage {
        let attachment: NSTextAttachment
        let range: NSRange
        let image: NSImage
        let originalSize: NSSize
        let name: String
    }
    var inlineImages: [InlineImage] = []
    var isReplacingDocument = false
    private var isFittingImages = false
    var activate: (() -> Void)?
    var onKeyboardScroll: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        if [115, 116, 119, 121].contains(event.keyCode) { onKeyboardScroll?() }
    }
    var onOpenImage: (NSImage, String) -> Void = { MapPreview.show(image: $0, title: $1) }
    @discardableResult func openImage(at index: Int) -> Bool {
        guard let item = inlineImages.first(where: { NSLocationInRange(index, $0.range) }) else { return false }
        onOpenImage(item.image, item.name); return true
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); fitImages()
        (superview as? ReaderDocumentView)?.updateExtent()
    }
    func fitImages() {
        guard !isReplacingDocument, !isFittingImages else { return }
        isFittingImages = true
        defer { isFittingImages = false }
        let width = max(1, bounds.width - textContainerInset.width * 2 - (textContainer?.lineFragmentPadding ?? 0) * 2)
        for image in inlineImages {
            guard image.range.location >= 0, NSMaxRange(image.range) <= (string as NSString).length else { continue }
            let factor = min(1, width / image.originalSize.width)
            let size = NSSize(width: image.originalSize.width * factor, height: image.originalSize.height * factor)
            guard image.attachment.bounds.size != size else { continue }
            image.attachment.bounds = NSRect(origin: .zero, size: size)
            layoutManager?.invalidateLayout(forCharacterRange: image.range, actualCharacterRange: nil)
            layoutManager?.invalidateDisplay(forCharacterRange: image.range)
        }
    }
    private struct LinkMenuAction { let link: LegacyInlineLink; let newReader: Bool }
    override func menu(for event: NSEvent) -> NSMenu? {
        let nativeMenu = super.menu(for: event)
        guard let layout = layoutManager, let container = textContainer, !isReplacingDocument else { return nativeMenu }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x; point.y -= textContainerOrigin.y
        let glyph = layout.glyphIndex(for: point, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point),
              let link = sourceLinks.first(where: { NSLocationInRange(layout.characterIndexForGlyph(at: glyph), $0.range) }) else { return nativeMenu }
        activate?(); linkPreview.cancelHover()
        // The system's Open/Copy Link entries refer to our private renderer URL.
        // Resource links instead receive typed local actions and standard text
        // commands. Ordinary text keeps its complete native context menu.
        let menu = NSMenu()
        menu.autoenablesItems = false
                for (index, newReader) in [false, true].enumerated() {
            let title = L(newReader ? "Abrir en otra lectura" : "Abrir aquí")
            let item = NSMenuItem(title: title, action: #selector(openLinkFromMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = LinkMenuAction(link: link, newReader: newReader)
            menu.insertItem(item, at: index)
        }
        menu.addItem(.separator())
        let copy = NSMenuItem(title: L("Copiar selección"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copy.target = self; copy.isEnabled = selectedRange().length > 0; menu.addItem(copy)
        let select = NSMenuItem(title: L("Seleccionar todo"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        select.target = self; select.isEnabled = !string.isEmpty; menu.addItem(select)
        return menu
    }
    @objc private func openLinkFromMenu(_ item: NSMenuItem) {
        guard let action = item.representedObject as? LinkMenuAction else { return }
        linkPreview.openSourceLink(action.link, newReader: action.newReader, window: window)
    }
    override func mouseDown(with event: NSEvent) {
        linkPreview.cancelHover()
        activate?()
        if event.clickCount == 2, let layoutManager, let textContainer {
            var point = convert(event.locationInWindow, from: nil)
            point.x -= textContainerOrigin.x; point.y -= textContainerOrigin.y
            let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
            if glyph < layoutManager.numberOfGlyphs,
               layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(point),
               openImage(at: layoutManager.characterIndexForGlyph(at: glyph)) { return }
        }
        super.mouseDown(with: event)
    }
}
