import AppKit
import SwiftUI

struct PanePointer {
    let windowPoint: CGPoint
    let canvasX: CGFloat
    let canvasY: CGFloat
}
struct PaneCanvasSurface: NSViewRepresentable {
    let workspace: StudyWorkspace
    final class CanvasView: NSView {
        var workspace: StudyWorkspace?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .mouseMoved, .leftMouseDragged]) { [weak self] event in
                MainActor.assumeIsolated {
                    if event.type == .mouseMoved || event.type == .leftMouseDragged {
                        if let locked = PanePointerSurface.PointerView.dragCursor { locked.set() }
                        else if event.window === self?.window, let cursor = self?.resizeCursor(at: event.locationInWindow) { cursor.set() }
                    } else { self?.activatePane(at: event) }
                }
                return event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
        func resizeCursor(at windowPoint: CGPoint) -> NSCursor? {
            guard let workspace, !workspace.showsHome, window?.attachedSheet == nil else { return nil }
            let point = convert(windowPoint, from: nil)
            guard bounds.contains(point) else { return nil }
            let ordered = workspace.presentedReaders.sorted {
                if ($0.id == workspace.activeID) != ($1.id == workspace.activeID) { return $0.id == workspace.activeID }
                return workspace.stackingLevel(of: $0) > workspace.stackingLevel(of: $1)
            }
            for reader in ordered {
                guard !reader.isMaximized else { return nil }
                let f = reader.frame
                let rect = CGRect(x: f.x * bounds.width, y: f.y * bounds.height,
                                  width: f.width * bounds.width, height: f.height * bounds.height)
                if let edge = PaneEdge.hit(at: point, in: rect) { return PaneResizeOverlay.cursor(edge) }
                if rect.contains(point) { return nil }
            }
            return nil
        }
        private func activatePane(at event: NSEvent) {
            guard let window, event.window === window, let workspace, !workspace.showsHome,
                  window.attachedSheet == nil else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), bounds.width > 0, bounds.height > 0 else { return }
            if let root = window.contentView,
               root.hitTest(root.convert(event.locationInWindow, from: nil)) is PanePointerSurface.PointerView {
                return // The title/resize surface owns activation for this event.
            }
            let normalized = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
            let reader = workspace.presentedReaders.filter { reader in
                let f = reader.isMaximized ? PaneFrame(x: 0, y: 0, width: 1, height: 1) : reader.frame
                return CGRect(x: f.x, y: f.y, width: f.width, height: f.height).contains(normalized)
            }.max { workspace.stackingLevel(of: $0) < workspace.stackingLevel(of: $1) }
            guard let reader else { return }
            workspace.activate(reader)
            // Preserve native field editing; blank areas and non-editing controls
            // release the previous pane's editor before AppKit handles the click.
            var hit = window.contentView.map { $0.hitTest($0.convert(event.locationInWindow, from: nil)) } ?? nil
            var editing = false
            while let view = hit {
                if view is NSTextField || (view as? NSTextView)?.isEditable == true { editing = true; break }
                hit = view.superview
            }
            if !editing { window.makeFirstResponder(nil) }
        }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    static func find(in view: NSView) -> CanvasView? {
        if let canvas = view as? CanvasView { return canvas }
        for child in view.subviews { if let canvas = find(in: child) { return canvas } }
        return nil
    }
    func makeNSView(context: Context) -> CanvasView { let view = CanvasView(); view.workspace = workspace; return view }
    func updateNSView(_ view: CanvasView, context: Context) { view.workspace = workspace }
    static func dismantleNSView(_ view: CanvasView, coordinator: ()) { view.stop() }
}
struct PanePointerSurface: NSViewRepresentable {
    var cursor: NSCursor
    var doubleClick: () -> Void = {}
    var began: (PanePointer) -> Void
    var changed: (PanePointer) -> Void
    var ended: () -> Void
    func makeNSView(context: Context) -> PointerView { let view = PointerView(); view.actions = self; return view }
    func updateNSView(_ view: PointerView, context: Context) {
        let changed = view.actions.cursor !== cursor
        view.actions = self
        if changed && !view.isDragging { view.window?.invalidateCursorRects(for: view) }
    }
    static func dismantleNSView(_ view: PointerView, coordinator: ()) { if view.isDragging { view.cancelOperation(nil) } }
    final class PointerView: NSView {
        var actions: PanePointerSurface!
        static var dragCursor: NSCursor?
        var isDragging = false
        weak var canvas: PaneCanvasSurface.CanvasView?
        private var cursorTracking: NSTrackingArea?
        override func updateTrackingAreas() {
            if let cursorTracking { removeTrackingArea(cursorTracking) }
            super.updateTrackingAreas()
            let tracking = NSTrackingArea(rect: .zero,
                options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil)
            cursorTracking = tracking; addTrackingArea(tracking)
        }
        private func updatePointerCursor(_ event: NSEvent) {
            if let locked = Self.dragCursor { locked.set(); return }
            guard let root = window?.contentView else { return }
            if let cursor = PaneCanvasSurface.find(in: root)?.resizeCursor(at: event.locationInWindow) { cursor.set(); return }
            let hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
            if let surface = hit as? PointerView { surface.actions.cursor.set() }
            else if event.type == .mouseExited { NSCursor.arrow.set() }
        }
        override func cursorUpdate(with event: NSEvent) { updatePointerCursor(event) }
        override func mouseEntered(with event: NSEvent) { updatePointerCursor(event) }
        override func mouseMoved(with event: NSEvent) { updatePointerCursor(event) }
        override func mouseExited(with event: NSEvent) { updatePointerCursor(event) }

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: Self.dragCursor ?? actions.cursor) }
        private func pointer(_ event: NSEvent) -> PanePointer {
            let p = canvas?.convert(event.locationInWindow, from: nil) ?? .zero
            return .init(windowPoint: event.locationInWindow, canvasX: p.x, canvasY: p.y)
        }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { actions.doubleClick(); return }
            if let root = window?.contentView { canvas = PaneCanvasSurface.find(in: root) }
            isDragging = true; Self.dragCursor = actions.cursor
            actions.cursor.push()
            actions.began(pointer(event))
        }
        override func mouseDragged(with event: NSEvent) { actions.cursor.set(); actions.changed(pointer(event)) }
        private func finishDrag() {
            actions.ended()
            if isDragging { isDragging = false; Self.dragCursor = nil; NSCursor.pop() }
        }
        override func mouseUp(with event: NSEvent) { finishDrag(); updatePointerCursor(event) }
        override func cancelOperation(_ sender: Any?) { finishDrag() }
    }
}

struct PaneResizeOverlay: View {
    let reader: ReaderSession
    let workspace: StudyWorkspace
    let canvas: CGSize
    @RebuildViewState private var origin: PaneFrame?
    @RebuildViewState private var pointer: CGPoint?
    @RebuildViewState private var snapState = PaneResizeSnapState()
    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(PaneEdge.allCases.enumerated()), id: \.offset) { _, edge in
                let rect = handle(edge, size: geometry.size)
                PanePointerSurface(cursor: Self.cursor(edge), began: { value in
                    workspace.activate(reader); origin = reader.frame; pointer = value.windowPoint
                    snapState = .init(); reader.unsnappedFrame = nil
                }, changed: { value in
                    guard let origin, let pointer else { return }
                    let requested = edge.resizing(origin, by: .init(width: value.windowPoint.x - pointer.x,
                        height: pointer.y - value.windowPoint.y), canvas: canvas)
                    let peers = workspace.presentedReaders
                        .filter { $0.id != reader.id && !$0.isMaximized }
                        .map { PaneResizeSnapPeer(id: $0.id, frame: $0.frame) }
                    let result = snapState.apply(requested, from: origin, edge: edge,
                                                 peers: peers, canvas: canvas)
                    if result.releasedWithSpring {
                        PaneLayoutMotion.springBreakaway { reader.frame = result.frame }
                    } else { reader.frame = result.frame }
                }, ended: { origin = nil; pointer = nil; snapState = .init() })
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    .accessibilityLabel(L(edge.title))
                    .accessibilityAdjustableAction { direction in
                        workspace.activate(reader)
                        let amount: CGFloat = direction == .increment ? 20 : -20
                        reader.frame = edge.resizing(reader.frame, by: .init(
                            width: edge.left ? -amount : amount, height: edge.top ? -amount : amount), canvas: canvas)
                    }
            }
        }.environment(\.layoutDirection, .leftToRight)
    }
    static func cursor(_ edge: PaneEdge) -> NSCursor {
        if edge == .left || edge == .right { return .resizeLeftRight }
        if edge == .top || edge == .bottom { return .resizeUpDown }
        if #available(macOS 15, *) {
            return NSCursor.frameResize(position: edge == .topLeft ? .topLeft : edge == .topRight ? .topRight : edge == .bottomLeft ? .bottomLeft : .bottomRight, directions: .all)
        }
        return edge == .topLeft || edge == .bottomRight ? Self.northwestSoutheast : Self.northeastSouthwest
    }
    // macOS 14 predates the system corner-resize cursor API. Preserve diagonal
    // affordances there with a small deterministic vector cursor.
    private static let northwestSoutheast = diagonalCursor(rising: false)
    private static let northeastSouthwest = diagonalCursor(rising: true)
    private static func diagonalCursor(rising: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { .init(x: x, y: rising ? y : 24-y) }
            let path = NSBezierPath()
            path.move(to: point(5, 5)); path.line(to: point(19, 19))
            path.move(to: point(5, 11)); path.line(to: point(5, 5)); path.line(to: point(11, 5))
            path.move(to: point(13, 19)); path.line(to: point(19, 19)); path.line(to: point(19, 13))
            path.lineJoinStyle = .round; path.lineCapStyle = .round
            NSColor.white.setStroke(); path.lineWidth = 3.5; path.stroke()
            NSColor.black.setStroke(); path.lineWidth = 1.5; path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: .init(x: 12, y: 12))
    }
    private func handle(_ edge: PaneEdge, size: CGSize) -> CGRect {
        let t: CGFloat = 7, c: CGFloat = 12, w = size.width, h = size.height
        switch edge {
        case .left: return .init(x: 0, y: c, width: t, height: max(0, h - c*2))
        case .right: return .init(x: w-t, y: c, width: t, height: max(0, h-c*2))
        case .top: return .init(x: c, y: 0, width: max(0, w-c*2), height: t)
        case .bottom: return .init(x: c, y: h-t, width: max(0, w-c*2), height: t)
        case .topLeft: return .init(x: 0, y: 0, width: c, height: c)
        case .topRight: return .init(x: w-c, y: 0, width: c, height: c)
        case .bottomLeft: return .init(x: 0, y: h-c, width: c, height: c)
        case .bottomRight: return .init(x: w-c, y: h-c, width: c, height: c)
        }
    }
}
