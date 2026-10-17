import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

struct PaneGeometryTests {
    let canvas = CGSize(width: 1000, height: 800)
    let origin = PaneFrame(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
    @Test func resizingMeetsNeighborThenResistsBeforeSpringRelease() {
        let start = PaneFrame(x: 0, y: 0, width: 0.45, height: 0.7)
        let peers = [PaneResizeSnapPeer(id: UUID(), frame: .init(x: 0.5, y: 0, width: 0.5, height: 0.7))]
        var snap = PaneResizeSnapState()
        func requested(_ width: Double) -> PaneFrame { .init(x: 0, y: 0, width: width, height: 0.7) }
        let captured = snap.apply(requested(0.492), from: start, edge: .right, peers: peers, canvas: canvas)
        #expect(captured.frame.width == 0.5)
        #expect(!captured.releasedWithSpring)
        let held = snap.apply(requested(0.525), from: start, edge: .right, peers: peers, canvas: canvas)
        #expect(held.frame.width == 0.5)
        let released = snap.apply(requested(0.54), from: start, edge: .right, peers: peers, canvas: canvas)
        #expect(released.frame.width == 0.54)
        #expect(released.releasedWithSpring)
        #expect(snap.apply(requested(0.56), from: start, edge: .right, peers: peers, canvas: canvas).releasedWithSpring)
    }
    @Test func alreadyTouchingPanesResistIntoNeighborAndSeparateFreely() {
        let left = PaneFrame(x: 0, y: 0, width: 0.5, height: 1)
        let right = PaneFrame(x: 0.5, y: 0, width: 0.5, height: 1)
        let peers = [PaneResizeSnapPeer(id: UUID(), frame: right)]
        var into = PaneResizeSnapState()
        let held = into.apply(.init(x: 0, y: 0, width: 0.52, height: 1), from: left, edge: .right, peers: peers, canvas: canvas)
        #expect(held.frame == left)
        var away = PaneResizeSnapState()
        let separated = away.apply(.init(x: 0, y: 0, width: 0.49, height: 1), from: left, edge: .right, peers: peers, canvas: canvas)
        #expect(separated.frame.width == 0.49)
        #expect(!separated.releasedWithSpring)
        var mirrored = PaneResizeSnapState()
        let otherSide = mirrored.apply(.init(x: 0.48, y: 0, width: 0.52, height: 1), from: right, edge: .left,
                                      peers: [.init(id: UUID(), frame: left)], canvas: canvas)
        #expect(otherSide.frame == right)
    }
    @Test func cornerSnapUsesBothAxesAndIgnoresNonOverlappingPanes() {
        let start = PaneFrame(x: 0.1, y: 0.1, width: 0.35, height: 0.35)
        let requested = PaneFrame(x: 0.1, y: 0.1, width: 0.395, height: 0.395)
        let peers = [PaneResizeSnapPeer(id: UUID(), frame: .init(x: 0.5, y: 0.1, width: 0.3, height: 0.7)),
                     PaneResizeSnapPeer(id: UUID(), frame: .init(x: 0.1, y: 0.5, width: 0.7, height: 0.3))]
        var corner = PaneResizeSnapState()
        let result = corner.apply(requested, from: start, edge: .bottomRight, peers: peers, canvas: canvas)
        #expect(abs(result.frame.width - 0.4) < 0.000001)
        #expect(abs(result.frame.height - 0.4) < 0.000001)
        var disjoint = PaneResizeSnapState()
        let untouched = disjoint.apply(requested, from: start, edge: .right,
            peers: [.init(id: UUID(), frame: .init(x: 0.5, y: 0.8, width: 0.5, height: 0.2))], canvas: canvas)
        #expect(untouched.frame == requested)
    }
    @Test func topEdgeHoverIncludesTheTitleBoundaryWithoutRequiringAClick() {
        let rect = CGRect(x: 100, y: 100, width: 500, height: 400)
        #expect(PaneEdge.hit(at: .init(x: 350, y: 100), in: rect) == .top)
        #expect(PaneEdge.hit(at: .init(x: 350, y: 106), in: rect) == .top)
        #expect(PaneEdge.hit(at: .init(x: 350, y: 120), in: rect) == nil)
        #expect(PaneEdge.hit(at: .init(x: 602, y: 250), in: rect) == .right)
        #expect(PaneEdge.hit(at: .init(x: 100, y: 100), in: rect) == .topLeft)
        #expect(PaneEdge.hit(at: .init(x: 350, y: 90), in: rect) == nil)
    }
    @Test func allEightEdgesKeepOppositeEdgesAnchoredAndStayInsideCanvas() {
        for edge in PaneEdge.allCases {
            for delta in [CGSize(width: 100, height: 80), CGSize(width: -5000, height: -5000), CGSize(width: 5000, height: 5000)] {
                let f = edge.resizing(origin, by: delta, canvas: canvas)
                #expect(f.x >= 0 && f.y >= 0 && f.x + f.width <= 1.000001 && f.y + f.height <= 1.000001)
                #expect(f.width >= 0.32 - 0.000001 && f.height >= 0.25 - 0.000001)
                if edge.left { #expect(abs(f.x + f.width - 0.7) < 0.000001) }
                if edge.top { #expect(abs(f.y + f.height - 0.7) < 0.000001) }
                if edge.right { #expect(f.x == origin.x) }
                if edge.bottom { #expect(f.y == origin.y) }
            }
        }
        #expect(abs(PaneEdge.left.resizing(origin, by: .init(width: 100, height: 0), canvas: canvas).x - 0.3) < 0.000001)
    }
    @Test func smallTilesDoNotJumpOnPickupAndInvalidCanvasIsIgnored() {
        let small = PaneFrame(x: 0, y: 0, width: 0.1, height: 0.1)
        #expect(PaneEdge.bottomRight.resizing(small, by: .zero, canvas: canvas) == small)
        #expect(PaneEdge.topLeft.resizing(origin, by: .init(width: 20, height: 20), canvas: .zero) == origin)
    }
    @Test func movingANarrowResizedPaneNeverChangesItsSizeAndClampsPosition() {
        let narrow = PaneFrame(x: 0.6, y: 0.1, width: 0.15, height: 0.8)
        let moved = narrow.moved(by: .init(width: 5000, height: -5000), canvas: canvas)
        #expect(moved.width == 0.15 && moved.height == 0.8)
        #expect(moved.x == 0.85 && moved.y == 0)
    }
    @Test func pointerSnapTargetsCoverCornersSidesAndReleaseAwayFromEdges() {
        let cases: [(CGPoint, PaneSnap?)] = [(.init(x: 2, y: 2), .topLeft), (.init(x: 998, y: 2), .topRight),
            (.init(x: 2, y: 798), .bottomLeft), (.init(x: 998, y: 798), .bottomRight),
            (.init(x: 2, y: 400), .left), (.init(x: 998, y: 400), .right),
            (.init(x: 500, y: 2), .full), (.init(x: 500, y: 798), .bottom),
            (.init(x: 500, y: 400), nil), (.init(x: -200, y: 100), nil)]
        for (point, expected) in cases { #expect(PaneSnap.target(at: point, canvas: canvas) == expected) }
    }
    @Test func everyDiagramExactlyPartitionsDesktopWithoutOverlap() {
        for layout in PaneLayout.allCases {
            #expect(abs(layout.frames.map { $0.width * $0.height }.reduce(0, +) - 1) < 0.000001)
            for (i, a) in layout.frames.enumerated() {
                for b in layout.frames.dropFirst(i+1) {
                    let overlapW = min(a.x+a.width, b.x+b.width) - max(a.x,b.x)
                    let overlapH = min(a.y+a.height, b.y+b.height) - max(a.y,b.y)
                    #expect(overlapW <= 0.000001 || overlapH <= 0.000001)
                }
            }
        }
    }
    @Test func layoutHoverMatchesEveryVisibleTileIncludingLeftAndRightSides() {
        for size in [CGSize(width: 96, height: 62), CGSize(width: 192, height: 124)] {
            for layout in PaneLayout.allCases {
                for slot in layout.frames.indices {
                    let rect = layout.diagramRect(for: slot, size: size)
                    for point in [CGPoint(x: rect.midX, y: rect.midY), CGPoint(x: rect.minX + 0.5, y: rect.minY + 0.5),
                                  CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.5)] {
                        #expect(layout.diagramSlot(at: point, size: size) == slot)
                    }
                }
                #expect(layout.diagramSlot(at: .zero, size: size) == nil)
                #expect(layout.diagramSlot(at: .init(x: size.width + 1, y: size.height/2), size: size) == nil)
            }
        }
        #expect(PaneLayout.halves.diagramSlot(at: .init(x: 24, y: 31), size: .init(width: 96, height: 62)) == 0)
        #expect(PaneLayout.halves.diagramSlot(at: .init(x: 72, y: 31), size: .init(width: 96, height: 62)) == 1)
        #expect(PaneLayout.halves.diagramSlot(at: .init(x: 48, y: 31), size: .init(width: 96, height: 62)) == nil)
    }
    @MainActor @Test func contextPlacementOnlyMovesItsExplicitTargetAndIgnoresClosedReaders() {
        let w = StudyWorkspace(personal: WorkspacePersonalState(url: FileManager.default.temporaryDirectory.appendingPathComponent("context-\(UUID()).json")))
        let resource = LibraryResource(location: URL(fileURLWithPath: "/authored/context.LSF"), title: "Test", byteCount: 0,
                                       format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        let readers = (0..<3).map { _ in w.open(resource, startReading: false) }
        let untouched = readers.dropFirst().map(\.frame)
        w.activate(readers[2])
        w.place(readers[0], layout: .quarters, slot: 2)
        #expect(readers[0].frame == PaneSnap.bottomLeft.frame)
        #expect(readers.dropFirst().map(\.frame) == untouched)
        #expect(w.activeReader === readers[0])
        let targetFrame = readers[0].frame
        w.place(readers[0], layout: .halves, slot: 20)
        #expect(readers[0].frame == targetFrame)
        w.close(readers[0]); w.place(readers[0], layout: .halves, slot: 0)
        #expect(readers.dropFirst().map(\.frame) == untouched)
        #expect(w.activeReader !== readers[0])
    }
    @MainActor @Test func titleContextHitTestingRejectsCoveredMinimizedAndHomeReaders() {
        let w = StudyWorkspace(personal: WorkspacePersonalState(url: FileManager.default.temporaryDirectory.appendingPathComponent("context-hit-\(UUID()).json")))
        let resource = LibraryResource(location: URL(fileURLWithPath: "/authored/context.LSF"), title: "Test", byteCount: 0,
                                       format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        let first = w.open(resource, startReading: false), second = w.open(resource, startReading: false)
        first.frame = PaneSnap.full.frame; second.frame = PaneSnap.right.frame
        #expect(w.frontmostReader(at: .init(x: 100, y: 100), canvas: canvas) === first)
        #expect(w.frontmostReader(at: .init(x: 900, y: 100), canvas: canvas) === second)
        w.minimize(second)
        #expect(w.frontmostReader(at: .init(x: 900, y: 100), canvas: canvas) === first)
        w.showsHome = true
        #expect(w.frontmostReader(at: .init(x: 100, y: 100), canvas: canvas) == nil)
    }
    @MainActor @Test func selectedTileKeepsActiveReaderAndMinimizedReadersAndPersistsPlacement() throws {
        let state = WorkspacePersonalState(url: FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID()).json"))
        let w = StudyWorkspace(personal: state)
        let r = LibraryResource(location: URL(fileURLWithPath: "/authored/test.LSF"), title: "Test", byteCount: 0,
                                format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        let readers = (0..<4).map { _ in w.open(r, startReading: false) }
        w.minimize(readers[1]); w.activate(readers[0]); let previous = readers[0].frame
        w.apply(.leftAndTwo, activeSlot: 2)
        #expect(w.activeReader === readers[0] && readers[1].isMinimized)
        #expect(readers[0].frame == PaneSnap.bottomRight.frame && readers[0].unsnappedFrame == previous)
        #expect(readers[2].frame == PaneSnap.left.frame && readers[3].frame == PaneSnap.topRight.frame)
        let archive = w.archive(); try archive.validate()
        #expect(archive.panes.last?.frame == PaneSnap.bottomRight.frame)
    }
}
