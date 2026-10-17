import AppKit
import SwiftUI

/// Observe secondary clicks only inside this title bar. The transparent view
/// leaves ordinary title dragging and the traffic-light buttons untouched.
struct PaneTitleContextMenu: NSViewRepresentable {
    let reader: ReaderSession
    let workspace: StudyWorkspace
    func makeNSView(context: Context) -> TitleContextView { TitleContextView(reader: reader, workspace: workspace) }
    func updateNSView(_ view: TitleContextView, context: Context) { view.reader = reader; view.workspace = workspace }
    static func dismantleNSView(_ view: TitleContextView, coordinator: ()) { view.stop() }

    final class TitleContextView: NSView {
        var reader: ReaderSession
        var workspace: StudyWorkspace
        private var monitor: Any?
        private var popover: NSPopover?
        init(reader: ReaderSession, workspace: StudyWorkspace) {
            self.reader = reader; self.workspace = workspace
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { stop(); return }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      let root = self.window?.contentView, let canvas = PaneCanvasSurface.find(in: root),
                      self.workspace.frontmostReader(at: canvas.convert(event.locationInWindow, from: nil), canvas: canvas.bounds.size) === self.reader else { return event }
                self.show(at: self.convert(event.locationInWindow, from: nil))
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            popover?.performClose(nil); popover = nil
        }
        private func show(at point: CGPoint) {
            popover?.performClose(nil)
            workspace.activate(reader)
            let popup = NSPopover()
            popup.behavior = .transient; popup.animates = false
            let panel = PaneLayoutPanel(workspace: workspace, targetReader: reader) { [weak self] in self?.popover?.performClose(nil) }
                .modifier(AppInterfaceLanguage())
            let controller = NSHostingController(rootView: panel)
            popup.contentViewController = controller
            popup.contentSize = controller.view.fittingSize
            popover = popup
            popup.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: self, preferredEdge: .minY)
        }
    }
}
