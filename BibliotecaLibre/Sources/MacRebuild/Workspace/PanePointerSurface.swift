import AppKit
import SwiftUI

struct PanePointer {
    let windowPoint: CGPoint
    let canvasX: CGFloat
    let canvasY: CGFloat
}
struct PaneCanvasSurface: NSViewRepresentable {
    final class CanvasView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    static func find(in view: NSView) -> CanvasView? {
        if let canvas = view as? CanvasView { return canvas }
        for child in view.subviews { if let canvas = find(in: child) { return canvas } }
        return nil
    }
    func makeNSView(context: Context) -> CanvasView { CanvasView() }
    func updateNSView(_ view: CanvasView, context: Context) {}
}
struct PanePointerSurface: NSViewRepresentable {
    var cursor: NSCursor
    var doubleClick: () -> Void = {}
    var began: (PanePointer) -> Void
    var changed: (PanePointer) -> Void
    var ended: () -> Void
    func makeNSView(context: Context) -> PointerView { let view = PointerView(); view.actions = self; return view }
    func updateNSView(_ view: PointerView, context: Context) { view.actions = self; view.window?.invalidateCursorRects(for: view) }
    final class PointerView: NSView {
        var actions: PanePointerSurface!
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
        override func cursorUpdate(with event: NSEvent) { actions.cursor.set() }
        override func mouseEntered(with event: NSEvent) { actions.cursor.set() }
        override func mouseMoved(with event: NSEvent) { actions.cursor.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: actions.cursor) }
        private func pointer(_ event: NSEvent) -> PanePointer {
            let p = canvas?.convert(event.locationInWindow, from: nil) ?? .zero
            return .init(windowPoint: event.locationInWindow, canvasX: p.x, canvasY: p.y)
        }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { actions.doubleClick(); return }
            if let root = window?.contentView { canvas = PaneCanvasSurface.find(in: root) }
            actions.began(pointer(event))
        }
        override func mouseDragged(with event: NSEvent) { actions.cursor.set(); actions.changed(pointer(event)) }
        override func mouseUp(with event: NSEvent) { actions.ended(); window?.invalidateCursorRects(for: self) }
        override func cancelOperation(_ sender: Any?) { actions.ended() }
    }
}

struct PaneResizeOverlay: View {
    let reader: ReaderSession
    let workspace: StudyWorkspace
    let canvas: CGSize
    @RebuildViewState private var origin: PaneFrame?
    @RebuildViewState private var pointer: CGPoint?
    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(PaneEdge.allCases.enumerated()), id: \.offset) { _, edge in
                let rect = handle(edge, size: geometry.size)
                PanePointerSurface(cursor: cursor(edge), began: { value in
                    workspace.activate(reader); origin = reader.frame; pointer = value.windowPoint
                    reader.unsnappedFrame = nil
                }, changed: { value in
                    guard let origin, let pointer else { return }
                    reader.frame = edge.resizing(origin, by: .init(width: value.windowPoint.x - pointer.x,
                        height: pointer.y - value.windowPoint.y), canvas: canvas)
                }, ended: { origin = nil; pointer = nil })
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
    private func cursor(_ edge: PaneEdge) -> NSCursor {
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
