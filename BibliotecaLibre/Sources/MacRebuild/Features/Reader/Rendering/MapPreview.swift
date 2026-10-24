import AppKit
import SwiftUI

@MainActor enum MapPreview {
    static func show(image: NSImage, title: String) {
        let controller = NSHostingController(rootView: MapPreviewView(image: image).modifier(AppInterfaceLanguage()))
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.setContentSize(NSSize(width: 960, height: 720))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        let owner = NSWindowController(window: window)
        let delegate = PreviewLifetime(owner: owner)
        window.delegate = delegate
        PreviewLifetime.windows[ObjectIdentifier(window)] = delegate
        window.center(); owner.showWindow(nil)
    }
}

@MainActor private final class PreviewLifetime: NSObject, NSWindowDelegate {
    static var windows: [ObjectIdentifier: PreviewLifetime] = [:]
    let owner: NSWindowController
    init(owner: NSWindowController) { self.owner = owner }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Self.windows.removeValue(forKey: ObjectIdentifier(window))
    }
}

private struct MapPreviewView: View {
    let image: NSImage
    @RebuildViewState private var zoom = 1.0
    @RebuildViewState private var fitsWidth = true
    var body: some View {
        VStack(spacing: 0) {
            MacReaderToolbarSurface {
                HStack(spacing: 8) {
                    MacReaderControlGroup {
                        Toggle(isOn: $fitsWidth) { MacToolbarLabel("Ajustar al ancho", "arrow.left.and.right") }
                            .toggleStyle(.button).help(L("Ajustar al ancho"))
                        Button(L("100 %")) { fitsWidth = false; zoom = 1 }
                    }
                    MacReaderControlGroup {
                        Slider(value: $zoom, in: 0.25...3).frame(minWidth: 60, idealWidth: 180, maxWidth: 180)
                            .disabled(fitsWidth).accessibilityLabel(L("Ampliación del mapa"))
                        Text("\(Int(zoom * 100)) %").monospacedDigit().frame(width: 50)
                    }
                    Spacer(minLength: 0)
                    MacReaderControlGroup {
                        MacToolbarButton("Copiar imagen", "doc.on.doc") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
                        }
                    }
                }
            }.padding(10)
            Divider()
            GeometryReader { geometry in
                let factor = fitsWidth ? min(1, max(1, geometry.size.width - 32) / image.size.width) : zoom
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: image.size.width * factor, height: image.size.height * factor)
                        .padding(16)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
            }
        }.modifier(MacPanelControlPresentation())
    }
}
