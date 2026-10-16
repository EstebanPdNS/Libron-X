import AppKit
import SwiftUI

/// Plain application title follows the expanded search field, as requested.
struct MacApplicationIdentity: View {
    var body: some View {
        Text("Libron-X").font(.headline).lineLimit(1)
            .accessibilityLabel("Libron-X").allowsHitTesting(false)
    }
}

struct MacWorkspaceTitlePresentation: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.toolbar(removing: .title) }
        else { content.background(HiddenLegacyWindowTitle()) }
    }
}

private struct HiddenLegacyWindowTitle: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ nsView: TitleView, context: Context) { nsView.window?.titleVisibility = .hidden }
    final class TitleView: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.titleVisibility = .hidden }
    }
}
