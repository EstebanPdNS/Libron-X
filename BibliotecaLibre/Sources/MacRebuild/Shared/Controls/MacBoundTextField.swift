import AppKit
import SwiftUI

/// Native editing and accessibility writes share the same immediate binding.
/// Updating AXValue must also update the field editor, so a later action cannot
/// read an old draft while accessibility displays a newer value.
struct MacBoundTextField: NSViewRepresentable {
    let title: String
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.layoutDirection) private var direction

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = field
        field.isEditable = true; field.isSelectable = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.alignment = .natural; field.baseWritingDirection = .natural
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if #available(macOS 26, *) {
            field.isBezeled = false; field.drawsBackground = false
        } else {
            field.isBezeled = true; field.drawsBackground = true; field.bezelStyle = .roundedBezel
        }
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        field.valueChanged = { text = $0 }
        field.isEnabled = isEnabled
        field.placeholderString = title; field.setAccessibilityLabel(title)
        field.userInterfaceLayoutDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
        field.alignment = text.isEmpty && direction == .rightToLeft ? .right : .natural
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
    }
    @MainActor final class Field: NSTextField, NSTextFieldDelegate {
        var valueChanged: ((String) -> Void)?
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
        }
        override var focusRingMaskBounds: NSRect {
            if #available(macOS 26, *) {
                bounds.insetBy(dx: -MacInputPresentation.horizontalPadding, dy: -MacInputPresentation.verticalPadding)
            } else { super.focusRingMaskBounds }
        }
        override func drawFocusRingMask() {
            if #available(macOS 26, *) {
                let rect = focusRingMaskBounds
                NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            } else { super.drawFocusRingMask() }
        }
        override func setAccessibilityValue(_ value: Any?) {
            guard isEnabled, isEditable, let value = value as? String else { return }
            stringValue = value
            currentEditor()?.string = value
            valueChanged?(value)
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        func controlTextDidChange(_ notification: Notification) { valueChanged?(stringValue) }
        func controlTextDidEndEditing(_ notification: Notification) { valueChanged?(stringValue) }
    }
}
