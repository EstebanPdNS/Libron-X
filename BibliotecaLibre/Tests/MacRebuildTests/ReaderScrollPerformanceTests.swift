import AppKit
import Observation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor @Suite(.serialized) struct ReaderScrollPerformanceTests {
    @Test func nativeReaderRetainsAppKitResponsiveScrolling() {
        #expect(ReaderScrollView.isCompatibleWithResponsiveScrolling)
    }
    @Test func repeatedActivationDoesNotInvalidateWorkspaceWhileRealActivationStillRaisesPane() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored text"]]); defer { fixture.remove() }
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")))
        let first = workspace.open(fixture.resources[0], startReading: false)
        let second = workspace.open(fixture.resources[0], startReading: false)
        let changes = ChangeCounter()
        withObservationTracking {
            _ = workspace.readers; _ = workspace.activeID; _ = workspace.showsHome; _ = second.isMinimized
        } onChange: { changes.increment() }
        for _ in 0..<1200 { workspace.activate(second) }
        #expect(changes.value == 0)
        workspace.activate(first)
        #expect(changes.value == 1 && workspace.readers.last === first && workspace.activeID == first.id)
        workspace.minimize(first); workspace.showsHome = true; workspace.activate(first)
        #expect(!first.isMinimized && !workspace.showsHome && workspace.activeID == first.id)
    }

    @Test func indexKeepsExactSourceOffsetsAndRefreshesWhenPageIsReplaced() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored text"]]); defer { fixture.remove() }
        let source = try LegacyContentReader.readSection(lsfURL: fixture.resources[0].location, ordinal: 0)
        func content(_ anchors: [LegacyReferenceAnchor]) -> LegacySectionContent {
            .init(descriptor: source.descriptor, plainText: source.plainText, runs: source.runs,
                  expectedCharacterCount: source.expectedCharacterCount, recognizedFormat: source.recognizedFormat,
                  paragraphs: source.paragraphs, anchors: anchors, markers: [], graphics: [], warnings: [], paragraphDocuments: nil)
        }
        let reader = ReaderSession(resource: fixture.resources[0])
        reader.page = .init(destination: .init(ordinal: 0), text: source.plainText, sectionCount: 1,
                            content: content([anchor("bible+rvr60.1.4.2", 7), anchor("Ge 4:1", 0)]))
        #expect(reader.bibleReference(at: 6) == "Ge 4:1" && reader.bibleReference(at: 7) == "Ge 4:2")
        #expect(reader.canSynchronizeBible && reader.bibleReferences.count == 2)
        reader.followBibleReference("Génesis 4:2")
        #expect(reader.selectedRange.location == 7 && !reader.isLoading)
        reader.page = .init(destination: .init(ordinal: 0), text: source.plainText, sectionCount: 1,
                            content: content([anchor("Jn 1:1", 3)]))
        #expect(reader.bibleReference(at: 7) == "Jn 1:1" && reader.bibleReferences == ["Jn 1:1"])
        reader.page = nil
        #expect(!reader.canSynchronizeBible && reader.bibleReferences.isEmpty && reader.bibleReference(at: 7) == nil)
    }

    @Test func sustainedScrollingSamplesLatestViewportWithoutWaitingForGestureToEnd() async throws {
        let (scroll, view, coordinator) = try surface()
        var offsets: [Int] = []
        coordinator.onVisiblePosition = { offsets.append($0) }
        for _ in 0..<12 {
            coordinator.userScrolled(scroll)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!offsets.isEmpty, "Continuous input must not postpone all synchronization until scrolling stops")
        view.alignCharacterToTop(coordinator.biblePositions[11].source, in: scroll)
        for _ in 0..<1000 { coordinator.userScrolled(scroll) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(offsets.last == coordinator.biblePositions[11].source)
        #expect(offsets.count <= 5, "Wheel ticks must share one pending viewport observation")
        coordinator.cancelViewportObservation()
    }

    @Test func pendingViewportCallbacksAreCancelledOnDocumentChangeAndTeardown() async throws {
        let (scroll, _, coordinator) = try surface()
        var calls = 0
        coordinator.onVisiblePosition = { _ in calls += 1 }
        coordinator.userScrolled(scroll); coordinator.cancelViewportObservation()
        try await Task.sleep(for: .milliseconds(120))
        #expect(calls == 0 && coordinator.scrollTask == nil)
        coordinator.userScrolled(scroll); coordinator.text = "A replacement document"
        try await Task.sleep(for: .milliseconds(120))
        #expect(calls == 0 && coordinator.scrollTask == nil)
        coordinator.userScrolled(scroll)
        ReaderTextView.dismantleNSView(scroll, coordinator: coordinator)
        try await Task.sleep(for: .milliseconds(120))
        #expect(calls == 0 && coordinator.scrollTask == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_SCROLL_BENCHMARK"] != nil))
    func referenceLookupCPUComparison() {
        let anchors = (1...176).map { anchor("bible+rvr60.19.119.\($0)", $0 * 100) }
        let index = ReaderBibleIndex(anchors: anchors)
        let start = ContinuousClock.now
        var oldResults: [String?] = []
        for tick in 0..<1200 {
            let references = anchors.compactMap { anchor -> (Int, String)? in
                guard let raw = anchor.reference, let query = LegacyPassageQuery.sourceReference(raw) else { return nil }
                return (anchor.characterOffset, query.displayReference)
            }
            oldResults.append((references.last { $0.0 <= (tick % 176 + 1) * 100 } ?? references.first)?.1)
        }
        let oldElapsed = start.duration(to: .now)
        let newStart = ContinuousClock.now
        let newResults = (0..<1200).map { index.reference(at: ($0 % 176 + 1) * 100) }
        let newElapsed = newStart.duration(to: .now)
        #expect(newResults == oldResults)
        print("Reference lookup CPU (1200 positions, 176 authored anchors): previous=\(oldElapsed), cached=\(newElapsed). This is not a presented-frame/FPS measurement.")
    }

    private func anchor(_ reference: String, _ offset: Int) -> LegacyReferenceAnchor {
        .init(reference: reference, flags: 0, dataTypeCode: 16, characterOffset: offset,
              decodedOffset: UInt64(offset), referenceFormatFlags: 0)
    }
    private func surface() throws -> (ReaderScrollView, ActiveTextView, ReaderTextView.Coordinator) {
        _ = NSApplication.shared
        let scroll = ReaderScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        let view = ActiveTextView(frame: scroll.bounds)
        view.isVerticallyResizable = true; view.textContainerInset = NSSize(width: 16, height: 16)
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.font = .systemFont(ofSize: 18)
        view.string = (1...30).map { "Authored verse \($0)\n" }.joined()
        scroll.documentView = view
        try #require(view.layoutManager).ensureLayout(for: #require(view.textContainer))
        let coordinator = ReaderTextView.Coordinator()
        coordinator.text = view.string; coordinator.identity = .init(ordinal: 0)
        coordinator.biblePositions = (1...30).map {
            let offset = (view.string as NSString).range(of: "Authored verse \($0)\n").location
            return (source: offset, visible: offset)
        }
        return (scroll, view, coordinator)
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}
