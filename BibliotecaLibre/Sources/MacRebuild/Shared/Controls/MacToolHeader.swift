import SwiftUI

/// Study sheets share the reader toolbar's native Glass, symbol size and close
/// action. Callers own their outer spacing; content never gains a glass overlay.
struct MacToolHeader: View {
    let title: String
    let close: () -> Void
    var body: some View {
        MacReaderToolbarSurface {
            HStack(spacing: 12) {
                Text(L(title)).font(.headline)
                Spacer(minLength: 16)
                MacReaderControlGroup {
                    MacToolbarButton("Cerrar", "xmark", action: close)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}
