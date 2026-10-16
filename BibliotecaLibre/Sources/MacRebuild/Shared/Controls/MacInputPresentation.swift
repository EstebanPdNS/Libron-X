import AppKit
import SwiftUI

/// Use the system's text-input bezel and focus ring instead of drawing a field
/// over a simulated glass image. One shape/size is shared by all single-line
/// inputs; older supported systems keep their native editing behavior.
private struct MacInputPresentation: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            content.textFieldStyle(.bordered).textInputBorderShape(.capsule).controlSize(.large)
        } else {
            compatibleInput(content)
        }
        #else
        compatibleInput(content)
        #endif
    }

    // Runtime availability alone cannot hide SDK 27 symbols from older compilers.
    @ViewBuilder private func compatibleInput(_ content: Content) -> some View {
        if #available(macOS 26, *) {
            content.textFieldStyle(.plain).controlSize(.large)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
        } else {
            content.textFieldStyle(.roundedBorder).controlSize(.large)
        }
    }
}

/// Dialogs and settings use the same native capsule controls as the toolbars.
/// Link buttons and borderless reader controls retain their explicit styles.
struct MacPanelControlPresentation: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
        } else { content.controlSize(.large) }
    }
}

extension View {
    func macInputStyle() -> some View { modifier(MacInputPresentation()) }
}

struct MacToolbarSearchSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.glassEffect(.regular, in: .capsule) }
        else { content }
    }
}

/// A genuine AppKit search field, permanently laid out as a field in the
/// leading toolbar. It never changes into an icon-only search item.
struct MacToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(frame: .zero)
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
        #if compiler(>=6.4)
        if #available(macOS 26, *) { field.borderShape = .capsule }
        #endif
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.maximumRecents = 0
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configure(field, context: context)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        configure(field, context: context)
    }
    private func configure(_ field: NSSearchField, context: Context) {
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.isEnabled = context.environment.isEnabled
        field.userInterfaceLayoutDirection = context.environment.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        // Progress updates must not replace an active field editor or disturb
        // selection, undo, or an unfinished input-method composition.
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: nsView.intrinsicContentSize.height)
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: MacToolbarSearchField
        init(_ parent: MacToolbarSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        @objc func submit(_ field: NSSearchField) {
            parent.text = field.stringValue
            guard !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            parent.onSubmit()
        }
    }
}
