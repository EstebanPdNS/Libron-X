import AppKit
import SwiftUI

/// The same native paragraph layout used by rich-text destinations. AppKit
/// adapts source colors for dark appearance without changing exported data.
struct MacAttributedPreview: NSViewRepresentable {
    let text: NSAttributedString
    /// Compact history snippets use SwiftUI text, without the full paragraph
    /// layout. Compare opaque black after conversion to one color space.
    static func inlineText(_ original: NSAttributedString) -> AttributedString {
        let copy = NSMutableAttributedString(attributedString: original)
        copy.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            if let color = value as? NSColor, let rgb = color.usingColorSpace(.sRGB),
               rgb.redComponent == 0, rgb.greenComponent == 0, rgb.blueComponent == 0, rgb.alphaComponent == 1 {
                copy.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        return AttributedString(copy)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(text) }

    @MainActor final class Coordinator {
        let scrollView = NSScrollView()
        let textView = NSTextView(frame: .zero)
        private var source: NSAttributedString?
        init() {
            scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true
            scrollView.hasHorizontalScroller = false; scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            textView.isEditable = false; textView.isSelectable = true; textView.isRichText = true
            textView.importsGraphics = false; textView.drawsBackground = false
            textView.usesAdaptiveColorMappingForDarkAppearance = true
            textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.setAccessibilityIdentifier("native.attributedPreview")
            scrollView.documentView = textView
        }
        func update(_ text: NSAttributedString) {
            textView.setAccessibilityLabel(L("Vista previa"))
            if source?.isEqual(to: text) != true {
                source = NSAttributedString(attributedString: text)
                textView.textStorage?.setAttributedString(text)
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }
}
