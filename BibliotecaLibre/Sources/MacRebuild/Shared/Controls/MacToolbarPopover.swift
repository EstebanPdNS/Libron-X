import AppKit
import SwiftUI

/// A fixed native popover avoids a SwiftUI presentation-preference feedback
/// loop in glass toolbar containers when the reading surface changes size.
private struct MacToolbarPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let size: NSSize
    let content: Content
    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        var binding: Binding<Bool>
        let popover = NSPopover()
        var pending = false
        init(_ binding: Binding<Bool>) {
            self.binding = binding
            super.init()
            popover.behavior = .transient
            popover.delegate = self
        }
        func update(anchor: NSView, size: NSSize, content: Content) {
            guard binding.wrappedValue else { popover.performClose(nil); return }
            guard !popover.isShown, !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self, weak anchor] in
                guard let self else { return }
                self.pending = false
                guard self.binding.wrappedValue, let anchor, anchor.window != nil else { return }
                let controller = NSHostingController(rootView: content.modifier(AppInterfaceLanguage()))
                controller.sizingOptions = []
                controller.view.frame = NSRect(origin: .zero, size: size)
                self.popover.contentViewController = controller
                self.popover.contentSize = size
                self.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            }
        }
        func popoverDidClose(_ notification: Notification) {
            binding.wrappedValue = false
            popover.contentViewController = nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator($isPresented) }
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.binding = $isPresented
        context.coordinator.update(anchor: view, size: size, content: content)
    }
    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) { coordinator.popover.performClose(nil) }
}
extension View {
    func macToolbarPopover<Content: View>(isPresented: Binding<Bool>, size: NSSize,
                                         @ViewBuilder content: () -> Content) -> some View {
        background(MacToolbarPopover(isPresented: isPresented, size: size, content: content()))
    }
}
