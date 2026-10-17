import AppKit
import SwiftUI

/// All pointer deltas are measured in a fixed native window coordinate space.
/// A moving SwiftUI view must never become its own gesture coordinate system.
extension PaneFrame {
    func moved(by delta: CGSize, canvas: CGSize) -> PaneFrame {
        guard canvas.width > 0, canvas.height > 0 else { return self }
        return .init(x: min(max(0, x + delta.width / canvas.width), 1 - width),
                     y: min(max(0, y + delta.height / canvas.height), 1 - height), width: width, height: height)
    }
}

enum PaneEdge: CaseIterable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    /// Canvas coordinates are top-down, including the title-bar edge.
    static func hit(at point: CGPoint, in rect: CGRect) -> PaneEdge? {
        guard rect.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        let left = abs(point.x - rect.minX) <= 7, right = abs(point.x - rect.maxX) <= 7
        let top = abs(point.y - rect.minY) <= 7, bottom = abs(point.y - rect.maxY) <= 7
        if top && left { return .topLeft }; if top && right { return .topRight }
        if bottom && left { return .bottomLeft }; if bottom && right { return .bottomRight }
        if top { return .top }; if bottom { return .bottom }
        if left { return .left }; if right { return .right }
        return nil
    }
    var left: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var right: Bool { self == .right || self == .topRight || self == .bottomRight }
    var top: Bool { self == .top || self == .topLeft || self == .topRight }
    var bottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var title: String {
        switch self {
        case .left: "Borde izquierdo"; case .right: "Borde derecho"
        case .top: "Borde superior"; case .bottom: "Borde inferior"
        case .topLeft: "Esquina superior izquierda"; case .topRight: "Esquina superior derecha"
        case .bottomLeft: "Esquina inferior izquierda"; case .bottomRight: "Esquina inferior derecha"
        }
    }
    func resizing(_ origin: PaneFrame, by delta: CGSize, canvas: CGSize) -> PaneFrame {
        guard canvas.width > 0, canvas.height > 0 else { return origin }
        // Never enlarge an already-small tiled pane merely by picking up its edge.
        let minW = min(origin.width, min(320 / canvas.width, 1))
        let minH = min(origin.height, min(200 / canvas.height, 1))
        var x1 = origin.x, x2 = origin.x + origin.width
        var y1 = origin.y, y2 = origin.y + origin.height
        if left { x1 = max(0, min(x2 - minW, origin.x + delta.width / canvas.width)) }
        if right { x2 = min(1, max(x1 + minW, x2 + delta.width / canvas.width)) }
        if top { y1 = max(0, min(y2 - minH, origin.y + delta.height / canvas.height)) }
        if bottom { y2 = min(1, max(y1 + minH, y2 + delta.height / canvas.height)) }
        return .init(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}

/// A neighboring pane boundary that a resize can magnetically meet.
struct PaneResizeSnapPeer {
    let id: UUID
    let frame: PaneFrame
}

private struct PaneResizeSnapLatch {
    let peerID: UUID
    let peerLeading: Bool
    /// Which side the dragged edge approached from. Crossing to the other side
    /// needs a deliberate pull so the edge feels held for a moment.
    let approachSide: CGFloat
}

struct PaneResizeSnapResult {
    let frame: PaneFrame
    let releasedWithSpring: Bool
}

/// Stateful resistance for window-to-window resizing. The edge stays aligned
/// while the pointer is in the release band, then springs through when the user
/// deliberately keeps pulling. Coordinates and thresholds are in canvas points.
struct PaneResizeSnapState {
    private var xLatch: PaneResizeSnapLatch?
    private var yLatch: PaneResizeSnapLatch?
    private var isBreakingThrough = false
    private let captureDistance: CGFloat = 12
    private let breakawayDistance: CGFloat = 36
    private let releaseDistance: CGFloat = 10

    mutating func apply(_ requested: PaneFrame, from origin: PaneFrame, edge: PaneEdge,
                        peers: [PaneResizeSnapPeer], canvas: CGSize) -> PaneResizeSnapResult {
        guard canvas.width > 0, canvas.height > 0 else { return .init(frame: requested, releasedWithSpring: false) }
        var x1 = CGFloat(requested.x) * canvas.width
        var x2 = CGFloat(requested.x + requested.width) * canvas.width
        var y1 = CGFloat(requested.y) * canvas.height
        var y2 = CGFloat(requested.y + requested.height) * canvas.height
        var spring = isBreakingThrough

        if edge.left || edge.right {
            let leading = edge.left
            let resolution = resolve(
                requested: leading ? x1 : x2,
                origin: CGFloat(leading ? origin.x : origin.x + origin.width) * canvas.width,
                opposite: leading ? x2 : x1,
                leading: leading,
                canvasLength: canvas.width,
                minimum: min(CGFloat(origin.width) * canvas.width, 320),
                orthogonalStart: y1, orthogonalEnd: y2,
                peers: peers, canvas: canvas, horizontal: true, latch: &xLatch
            )
            if leading { x1 = resolution.coordinate } else { x2 = resolution.coordinate }
            spring = spring || resolution.releasedWithSpring
        } else { xLatch = nil }

        if edge.top || edge.bottom {
            let leading = edge.top
            let resolution = resolve(
                requested: leading ? y1 : y2,
                origin: CGFloat(leading ? origin.y : origin.y + origin.height) * canvas.height,
                opposite: leading ? y2 : y1,
                leading: leading,
                canvasLength: canvas.height,
                minimum: min(CGFloat(origin.height) * canvas.height, 200),
                orthogonalStart: x1, orthogonalEnd: x2,
                peers: peers, canvas: canvas, horizontal: false, latch: &yLatch
            )
            if leading { y1 = resolution.coordinate } else { y2 = resolution.coordinate }
            spring = spring || resolution.releasedWithSpring
        } else { yLatch = nil }

        // Keep the released edge spring-following for the remainder of the
        // pointer drag so the gesture feels elastic instead of a one-frame pop.
        if spring { isBreakingThrough = true }

        return .init(frame: .init(x: Double(x1 / canvas.width), y: Double(y1 / canvas.height),
                                  width: Double((x2 - x1) / canvas.width), height: Double((y2 - y1) / canvas.height)),
                     releasedWithSpring: spring)
    }

    private func resolve(requested: CGFloat, origin: CGFloat, opposite: CGFloat, leading: Bool,
                         canvasLength: CGFloat, minimum: CGFloat,
                         orthogonalStart: CGFloat, orthogonalEnd: CGFloat,
                         peers: [PaneResizeSnapPeer], canvas: CGSize, horizontal: Bool,
                         latch: inout PaneResizeSnapLatch?) -> (coordinate: CGFloat, releasedWithSpring: Bool) {
        let lower = leading ? 0 : opposite + minimum
        let upper = leading ? opposite - minimum : canvasLength
        guard lower <= upper else { latch = nil; return (requested, false) }

        if let current = latch {
            guard let peer = peers.first(where: { $0.id == current.peerID }),
                  overlaps(peer.frame, start: orthogonalStart, end: orthogonalEnd,
                           canvas: canvas, horizontal: horizontal) else {
                latch = nil
                return (requested, false)
            }
            let coordinate = boundary(current.peerLeading, of: peer.frame, canvas: canvas, horizontal: horizontal)
            guard coordinate >= lower, coordinate <= upper else {
                latch = nil
                return (requested, false)
            }
            let signedDistance = (requested - coordinate) * current.approachSide
            if signedDistance > releaseDistance {
                latch = nil // The pointer returned to the side it came from.
                return (requested, false)
            }
            if signedDistance < -breakawayDistance {
                latch = nil // Intentional pull-through: let go with a spring.
                return (requested, true)
            }
            return (coordinate, false)
        }

        let candidate = peers
            .filter { overlaps($0.frame, start: orthogonalStart, end: orthogonalEnd,
                               canvas: canvas, horizontal: horizontal) }
            .flatMap { peer -> [(PaneResizeSnapPeer, Bool, CGFloat)] in
                let first = boundary(true, of: peer.frame, canvas: canvas, horizontal: horizontal)
                let last = boundary(false, of: peer.frame, canvas: canvas, horizontal: horizontal)
                return [(peer, true, first), (peer, false, last)]
            }
            .filter { _, peerLeading, coordinate in
                guard coordinate >= lower, coordinate <= upper else { return false }
                let startedDistance = origin - coordinate
                let currentDistance = requested - coordinate
                let crossedBoundary = startedDistance * currentDistance <= 0 && abs(startedDistance) > releaseDistance
                let movingTowardBoundary = (requested - origin) * (coordinate - origin) > 0
                let startedAtBoundary = abs(startedDistance) < 0.001
                let peerDirection: CGFloat = peerLeading ? 1 : -1
                let movingIntoPeer = startedAtBoundary && (requested - origin) * peerDirection > 0
                let closeEnough = abs(currentDistance) <= captureDistance
                let crossedAtSpeed = crossedBoundary && abs(currentDistance) <= breakawayDistance
                return crossedAtSpeed || (movingIntoPeer && abs(currentDistance) <= breakawayDistance)
                    || (closeEnough && (abs(startedDistance) > captureDistance || movingTowardBoundary || crossedBoundary))
            }
            .min { abs(requested - $0.2) < abs(requested - $1.2) }

        guard let (peer, peerLeading, coordinate) = candidate else { return (requested, false) }
        var approach = origin - coordinate
        if abs(approach) < 0.001 { approach = peerLeading ? -1 : 1 }
        latch = .init(peerID: peer.id, peerLeading: peerLeading, approachSide: approach < 0 ? -1 : 1)
        return (coordinate, false)
    }

    private func boundary(_ leading: Bool, of frame: PaneFrame, canvas: CGSize, horizontal: Bool) -> CGFloat {
        if horizontal { return CGFloat(leading ? frame.x : frame.x + frame.width) * canvas.width }
        return CGFloat(leading ? frame.y : frame.y + frame.height) * canvas.height
    }

    private func overlaps(_ frame: PaneFrame, start: CGFloat, end: CGFloat,
                          canvas: CGSize, horizontal: Bool) -> Bool {
        let peerStart = CGFloat(horizontal ? frame.y : frame.x) * (horizontal ? canvas.height : canvas.width)
        let peerEnd = CGFloat(horizontal ? frame.y + frame.height : frame.x + frame.width) * (horizontal ? canvas.height : canvas.width)
        let overlap = min(end, peerEnd) - max(start, peerStart)
        return overlap >= min(24, max(1, min(end - start, peerEnd - peerStart)))
    }
}

enum PaneSnap: CaseIterable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight, full
    var frame: PaneFrame {
        switch self {
        case .left: .init(x: 0, y: 0, width: 0.5, height: 1)
        case .right: .init(x: 0.5, y: 0, width: 0.5, height: 1)
        case .top: .init(x: 0, y: 0, width: 1, height: 0.5)
        case .bottom: .init(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft: .init(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: .init(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: .init(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .full: .init(x: 0, y: 0, width: 1, height: 1)
        }
    }
    static func target(at point: CGPoint, canvas: CGSize) -> Self? {
        guard canvas.width > 0, canvas.height > 0,
              point.x >= -40, point.x <= canvas.width + 40, point.y >= -40, point.y <= canvas.height + 40 else { return nil }
        let edge: CGFloat = 24, corner: CGFloat = min(90, min(canvas.width, canvas.height) * 0.2)
        let left = point.x <= edge, right = point.x >= canvas.width - edge
        let top = point.y <= edge, bottom = point.y >= canvas.height - edge
        if (left && point.y <= corner) || (top && point.x <= corner) { return .topLeft }
        if (right && point.y <= corner) || (top && point.x >= canvas.width - corner) { return .topRight }
        if (left && point.y >= canvas.height - corner) || (bottom && point.x <= corner) { return .bottomLeft }
        if (right && point.y >= canvas.height - corner) || (bottom && point.x >= canvas.width - corner) { return .bottomRight }
        if left { return .left }; if right { return .right }; if top { return .full }; if bottom { return .bottom }
        return nil
    }
}

enum PaneLayout: String, CaseIterable, Identifiable {
    case halves, wideLeft, thirds, leftAndTwo, rightAndTwo, quarters
    var id: String { rawValue }
    var title: String {
        switch self {
        case .halves: "Dos columnas"; case .wideLeft: "Columna amplia"; case .thirds: "Tres columnas"
        case .leftAndTwo: "Una a la izquierda y dos a la derecha"
        case .rightAndTwo: "Dos a la izquierda y una a la derecha"; case .quarters: "Cuadrícula de cuatro"
        }
    }
    /// Drawing and hover use the same local, untransformed rectangles. Tracking
    /// separate offset siblings can report a neighbor's pre-offset hover area.
    func diagramRect(for slot: Int, size: CGSize) -> CGRect {
        guard frames.indices.contains(slot), size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return .zero }
        let f = frames[slot]
        return CGRect(x: f.x * size.width, y: f.y * size.height,
                      width: f.width * size.width, height: f.height * size.height).insetBy(dx: 2, dy: 2)
    }
    func diagramSlot(at point: CGPoint, size: CGSize) -> Int? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return frames.indices.first { diagramRect(for: $0, size: size).contains(point) }
    }

    var frames: [PaneFrame] {
        switch self {
        case .halves: [PaneSnap.left.frame, PaneSnap.right.frame]
        case .wideLeft: [.init(x: 0, y: 0, width: 2/3, height: 1), .init(x: 2/3, y: 0, width: 1/3, height: 1)]
        case .thirds: (0..<3).map { .init(x: Double($0)/3, y: 0, width: 1/3, height: 1) }
        case .leftAndTwo: [PaneSnap.left.frame, PaneSnap.topRight.frame, PaneSnap.bottomRight.frame]
        case .rightAndTwo: [PaneSnap.topLeft.frame, PaneSnap.bottomLeft.frame, PaneSnap.right.frame]
        case .quarters: [PaneSnap.topLeft.frame, PaneSnap.topRight.frame, PaneSnap.bottomLeft.frame, PaneSnap.bottomRight.frame]
        }
    }
}

/// Commands share one animation transaction so every pane starts and finishes
/// together. Pointer movement bypasses this helper for immediate tracking.
@MainActor enum PaneLayoutMotion {
    static let duration: TimeInterval = 0.8
    static func perform(_ changes: () -> Void) {
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .easeInOut(duration: duration)
        withAnimation(animation, changes)
    }
    static func springBreakaway(_ changes: () -> Void) {
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .interpolatingSpring(stiffness: 260, damping: 22)
        withAnimation(animation, changes)
    }
}

extension StudyWorkspace {
    func toggleMaximized(_ reader: ReaderSession) {
        PaneLayoutMotion.perform {
            activate(reader)
            reader.isMaximized.toggle()
        }
    }
    func place(_ reader: ReaderSession, in frame: PaneFrame) {
        PaneLayoutMotion.perform { placeImmediately(reader, in: frame) }
    }
    private func placeImmediately(_ reader: ReaderSession, in frame: PaneFrame) {
        activate(reader)
        if reader.unsnappedFrame == nil { reader.unsnappedFrame = reader.frame }
        reader.isMaximized = false; reader.frame = frame
    }
    func place(_ reader: ReaderSession, layout: PaneLayout, slot: Int) {
        guard readers.contains(where: { $0 === reader }), layout.frames.indices.contains(slot) else { return }
        place(reader, in: layout.frames[slot])
    }
    func frontmostReader(at point: CGPoint, canvas: CGSize) -> ReaderSession? {
        guard !showsHome, canvas.width > 0, canvas.height > 0 else { return nil }
        let position = CGPoint(x: point.x / canvas.width, y: point.y / canvas.height)
        return readers.reversed().first { reader in
            guard !reader.isMinimized else { return false }
            let f = reader.isMaximized ? PaneSnap.full.frame : reader.frame
            return CGRect(x: f.x, y: f.y, width: f.width, height: f.height).contains(position)
        }
    }
    func apply(_ layout: PaneLayout, activeSlot: Int) {
        guard let activeReader, layout.frames.indices.contains(activeSlot) else { return }
        let others = orderedReaders.filter { !$0.isMinimized && $0 !== activeReader }
        let remaining = layout.frames.indices.filter { $0 != activeSlot }
        PaneLayoutMotion.perform {
            for (reader, slot) in zip(others, remaining) { placeImmediately(reader, in: layout.frames[slot]) }
            placeImmediately(activeReader, in: layout.frames[activeSlot]); snapPreview = nil
        }
    }
}
