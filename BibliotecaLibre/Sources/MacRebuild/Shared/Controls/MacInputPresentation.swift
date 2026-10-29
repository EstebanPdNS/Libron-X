import AppKit
import SwiftUI

/// The same real Glass capsule used by toolbar search, with native text editing.
/// Older supported systems keep their native field presentation.
struct MacInputPresentation: ViewModifier {
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 7
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.textFieldStyle(.plain).controlSize(.large)
                .padding(.horizontal, Self.horizontalPadding).padding(.vertical, Self.verticalPadding)
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
    func macEditorSurface() -> some View { modifier(MacEditorSurface()) }
}

/// A shared, rounded surface for multiline editing and previews.
private struct MacEditorSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        } else {
            content.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
        }
    }
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
