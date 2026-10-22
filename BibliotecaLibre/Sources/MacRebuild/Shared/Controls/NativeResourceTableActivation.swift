import AppKit
import SwiftUI

/// Activate the actual native table row, including empty space in its cells.
/// Keep single-click selection and keyboard navigation owned by the table.
struct NativeResourceTableActivation: NSViewRepresentable {
    var ids: [String]
    var open: (String) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.ids = ids; view.open = open }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stop() }
    @MainActor final class Anchor: NSView {
        var ids: [String] = []
        var open: ((String) -> Void)?
        var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window, event.clickCount == 2,
                          let content = window.contentView else { return false }
                    var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
                    while let view = hit, !(view is NSTableView) { hit = view.superview }
                    guard let table = hit as? NSTableView, table.numberOfRows == self.ids.count else { return false }
                    let row = table.row(at: table.convert(event.locationInWindow, from: nil))
                    guard self.ids.indices.contains(row) else { return false }
                    self.open?(self.ids[row])
                    return true
                }
                return handled ? nil : event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    }
}
