import AppKit

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

extension StudyWorkspace {
    func place(_ reader: ReaderSession, in frame: PaneFrame) {
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
        for (reader, slot) in zip(others, remaining) { place(reader, in: layout.frames[slot]) }
        place(activeReader, in: layout.frames[activeSlot]); snapPreview = nil
    }
}
