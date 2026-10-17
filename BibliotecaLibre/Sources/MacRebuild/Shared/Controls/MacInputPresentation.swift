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

/// Shared native text editing inside one Glass surface. The icon and clear
/// action participate in layout, including while AppKit's field editor is open.
struct MacToolbarSearchField: View {
    @Binding var text: String
    let prompt: String
    let onSubmit: () -> Void
    var onEditingBegan: () -> Void = {}
    var onEditingEnded: () -> Void = {}
    var body: some View {
        HStack(spacing: 7) {
            Button(action: submit) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
                .buttonStyle(.plain).accessibilityLabel(L("Buscar"))
            TextField(prompt, text: $text, onEditingChanged: { editing in if editing { onEditingBegan() } else { onEditingEnded() } })
                .textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit(submit).accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(L("Borrar"))
            }
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 32)
    }
    private func submit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSubmit()
    }
}
