import SwiftUI

/// SF Symbols remain system vector artwork. One optical scale, weight and
/// monochrome treatment is shared by every actionable toolbar symbol.
struct MacToolbarLabel: View {
    let title: String
    let symbol: String
    init(_ title: String, _ symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View {
        Label { Text(L(title)) } icon: {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .symbolVariant(.none)
                .font(.system(size: 16, weight: .regular))
                .imageScale(.medium)
                .frame(width: 20, height: 20)
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel(L(title))
        .featureHelpTarget(.resolve(labels: [L(title)], windowTitle: "", language: AppLanguage.saved()))
    }
}
struct MacToolbarButton: View {
    let title: String
    let symbol: String
    let horizontalInset: CGFloat
    let action: () -> Void
    init(_ title: String, _ symbol: String, horizontalInset: CGFloat = 0, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.horizontalInset = horizontalInset; self.action = action
    }
    private var helpTopic: HelpTopic {
        if title.contains("biblioteca") || title.contains("recurso") { return .library }
        if title.contains("Diccionario") { return .dictionary }
        if title.contains("actualiz") { return .updates }
        return .windows
    }
    var body: some View {
        Button(action: action) { MacToolbarLabel(title, symbol).padding(.horizontal, horizontalInset) }
            .help(L(title)).accessibilityLabel(L(title)).contextHelp(helpTopic)
    }
}

/// A native menu also owns a trailing disclosure indicator. Give its symbol
/// breathing room inside the glass capsule without changing the symbol scale.
struct MacToolbarMenuLabel: View {
    let title: String
    let symbol: String
    init(_ title: String, _ symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View {
        MacToolbarLabel(title, symbol).padding(.leading, 6).padding(.trailing, 4)
    }
}

/// Embedded toolbars share the native glass material with NSToolbar on modern
/// macOS. Earlier systems retain their standard native control group.
struct MacReaderControlGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            HStack(spacing: 10) { content }
                .buttonStyle(.borderless).menuStyle(.borderlessButton)
                .controlSize(.regular)
                .padding(.horizontal, 12).frame(height: 32)
                // The group is a persistent toolbar background, not one large
                // interactive button. Native child controls own press feedback.
                .glassEffect(.regular, in: .capsule)
        } else {
            ControlGroup { content }.controlGroupStyle(.automatic).controlSize(.regular)
        }
    }
}
struct MacReaderToolbarSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 4) { content }
        } else { content }
    }
}
