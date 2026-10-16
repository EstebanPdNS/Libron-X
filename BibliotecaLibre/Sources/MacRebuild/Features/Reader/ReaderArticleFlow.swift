import Foundation
import LibronixCore

/// A small window of complete physical articles. Their text, anchors, links,
/// selections and output coordinates remain source-local, never concatenated.
@MainActor extension ReaderSession {
    var readingFlowPages: [ReaderPage] {
        guard let page else { return [] }
        return flowPages.contains(where: { $0.destination.ordinal == page.destination.ordinal }) ? flowPages : [page]
    }
    func startReadingFlow() {
        flowEnabled = true
        if flowPages.isEmpty, let page { flowPages = [page] }
        fillReadingFlow()
    }
    func selectFlowPage(_ selected: ReaderPage, selection: NSRange) {
        guard readingFlowPages.contains(where: { $0.destination == selected.destination }),
              Range(selection, in: selected.text) != nil else { return }
        if page?.destination != selected.destination {
            page = selected
            viewportCharacterOffset = nil
        }
        selectedRange = selection
        // No selection request, viewport change or group navigation is emitted.
    }
    func observeFlowPage(_ ordinal: Int, offset: Int) {
        guard !isLoading, let target = readingFlowPages.first(where: { $0.destination.ordinal == ordinal }) else { return }
        if page?.destination != target.destination {
            page = target; selectedRange = .init(location: 0, length: 0)
            flowLookahead = 5
        }
        if history.last != target.destination {
            history = Array(history.prefix(historyIndex + 1)) + [target.destination]
            historyIndex = history.count - 1
        }
        observeBiblePosition(offset, fromViewport: true)
        // Retain the preceding article for upward scrolling. Everything still
        // visible below the current article stays in place while prefetch runs.
        if let index = flowPages.firstIndex(where: { $0.destination.ordinal == ordinal }), index > 1 {
            flowPages.removeFirst(index - 1)
        }
        fillReadingFlow()
    }
    func extendReadingFlowForViewport() {
        guard let current = page, let index = flowPages.firstIndex(where: { $0.destination.ordinal == current.destination.ordinal }),
              flowPages.count < 64 else { return }
        flowLookahead = min(64, max(flowLookahead, flowPages.count - index + 4))
        fillReadingFlow()
    }
    func fillReadingFlow() {
        guard flowEnabled, !isLoading, flowTask == nil, let current = page,
              current.oeb == nil, current.destination.endReference == nil,
              !ReaderBibleIndex(anchors: current.content?.anchors ?? [], textLength: current.text.utf16.count).entries.isEmpty else { return }
        let needsPrevious = flowPages.first?.destination.ordinal == current.destination.ordinal &&
            current.destination.ordinal > 0 && flowBeginningOrdinal != current.destination.ordinal
        let activeIndex = flowPages.firstIndex { $0.destination.ordinal == current.destination.ordinal } ?? 0
        let needsNext = flowPages.count < 64 && flowPages.count - activeIndex < flowLookahead &&
            flowPages.last.map { $0.destination.ordinal + 1 < $0.sectionCount && flowEndOrdinal != $0.destination.ordinal } == true
        guard needsPrevious || needsNext else { return }
        let token = flowGeneration
        flowTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.flowGeneration == token { self.flowTask = nil } }
            do {
                // One preceding article makes reverse scrolling continuous too.
                if needsPrevious, let first = self.flowPages.first {
                    let previous = try await self.readFlowArticle(first.destination.ordinal - 1)
                    guard token == self.flowGeneration, !Task.isCancelled else { return }
                    if try await self.confirmedFlowContinues(from: previous, to: first) {
                        guard token == self.flowGeneration, !Task.isCancelled else { return }
                        if self.canBuffer(previous) { self.flowPages.insert(previous, at: 0) }
                        else { self.flowBeginningOrdinal = first.destination.ordinal }
                    }
                    else { self.flowBeginningOrdinal = first.destination.ordinal }
                }
                while let active = self.page,
                      let position = self.flowPages.firstIndex(where: { $0.destination.ordinal == active.destination.ordinal }),
                      self.flowPages.count - position < self.flowLookahead, self.flowPages.count < 64,
                      let last = self.flowPages.last, last.destination.ordinal + 1 < last.sectionCount,
                      self.flowEndOrdinal != last.destination.ordinal {
                    let next = try await self.readFlowArticle(last.destination.ordinal + 1)
                    guard token == self.flowGeneration, !Task.isCancelled else { return }
                    guard try await self.confirmedFlowContinues(from: last, to: next) else { self.flowEndOrdinal = last.destination.ordinal; break }
                    guard token == self.flowGeneration, !Task.isCancelled else { return }
                    guard self.canBuffer(next) else { self.flowEndOrdinal = last.destination.ordinal; break }
                    self.flowPages.append(next)
                }
            } catch is CancellationError {}
            catch {
                if token == self.flowGeneration {
                    self.flowWarning = error.localizedDescription
                    self.flowBeginningOrdinal = self.flowPages.first?.destination.ordinal
                    self.flowEndOrdinal = self.flowPages.last?.destination.ordinal
                }
            }
        }
    }
    private func readFlowArticle(_ ordinal: Int) async throws -> ReaderPage {
        // Use the same checked decoder as explicit navigation, for both LSF and
        // Libronix containers. No edition name or format-specific offset guess.
        let next = try await readForFlow(.init(ordinal: ordinal))
        if let expected = flowPages.first?.sourceStamp, next.sourceStamp != expected { throw LegacyIndicesError.sourceChanged }
        return next
    }
    private func confirmedFlowContinues(from previous: ReaderPage, to next: ReaderPage) async throws -> Bool {
        guard Self.flowContinues(from: previous, to: next) else { return false }
        let left = ReaderBibleIndex(anchors: previous.content?.anchors ?? [], textLength: previous.text.utf16.count)
        let right = ReaderBibleIndex(anchors: next.content?.anchors ?? [], textLength: next.text.utf16.count)
        if left.references.count == 1, let reference = left.entries.last?.reference,
           LegacyPassageQuery.sourceReference(reference)?.normalizedKey == right.entries.first.flatMap({ LegacyPassageQuery.sourceReference($0.reference) })?.normalizedKey {
            let resolved = try await readForFlow(.init(ordinal: previous.destination.ordinal, reference: reference))
            if let expected = previous.sourceStamp, resolved.sourceStamp != expected { throw LegacyIndicesError.sourceChanged }
            return resolved.destination.ordinal == previous.destination.ordinal
        }
        return true
    }
    private func canBuffer(_ next: ReaderPage) -> Bool {
        let textUnits = flowPages.reduce(next.text.utf16.count) { $0 + $1.text.utf16.count }
        let imageBytes = (flowPages + [next]).reduce(0) { $0 + $1.graphics.reduce(0) { $0 + $1.data.count } }
        guard textUnits <= 2_000_000, imageBytes <= 64 * 1_024 * 1_024 else {
            flowWarning = L("Este tramo es demasiado grande para continuar automáticamente. Usa Artículo siguiente.")
            return false
        }
        return true
    }
    nonisolated static func flowContinues(from previous: ReaderPage, to next: ReaderPage) -> Bool {
        guard next.destination.ordinal == previous.destination.ordinal + 1,
              let lastReference = ReaderBibleIndex(anchors: previous.content?.anchors ?? [], textLength: previous.text.utf16.count).entries.last?.reference,
              let firstReference = ReaderBibleIndex(anchors: next.content?.anchors ?? [], textLength: next.text.utf16.count).entries.first?.reference,
              let endingReference = ReaderBibleIndex(anchors: next.content?.anchors ?? [], textLength: next.text.utf16.count).entries.last?.reference,
              let last = LegacyPassageQuery.sourceReference(lastReference),
              let first = LegacyPassageQuery.sourceReference(firstReference),
              let ending = LegacyPassageQuery.sourceReference(endingReference) else { return false }
        if last.sourceBookKey == first.sourceBookKey {
            // Some sources split a single verse between two physical articles.
            // Keep both halves, but require the following article to progress.
            let startsAtOrAfter = first.chapter > last.chapter || (first.chapter == last.chapter && first.verse >= last.verse)
            let endsAfter = ending.chapter > last.chapter || (ending.chapter == last.chapter && ending.verse > last.verse)
            return startsAtOrAfter && endsAfter
        }
        return first.chapter == 1 && first.verse == 1
    }
}
