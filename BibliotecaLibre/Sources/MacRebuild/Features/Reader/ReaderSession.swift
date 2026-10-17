import Foundation
import LibronixCore
import Observation
import WebKit

struct ReaderDestination: Equatable, Sendable, Codable {
    var ordinal: Int
    var reference: String? = nil
    /// Only a new library-open request uses this hint. Committed destinations
    /// always contain the resolved physical ordinal, including explicit zero.
    var prefersContentsStart: Bool? = nil
    var endReference: String? = nil
    var requiredEdition: String? = nil
    var passageStartReference: String? = nil
}
struct ReaderEntry: Codable, Identifiable, Sendable {
    var id: Int
    var ordinal: Int
    var title: String
    var depth: Int = 0
}
struct ReaderPage: Sendable {
    var destination: ReaderDestination
    var text: String
    var sectionCount: Int
    var entries: [ReaderEntry] = []
    var selection: NSRange? = nil
    var warning: String? = nil
    var content: LegacySectionContent? = nil
    var typography: LegacyTypography? = nil
    var graphics: [LegacyGraphicAsset] = []
    var inlineLinks: [LegacyInlineLink] = []
    var interlinearLines: [LibronixInterlinearLineDefinition] = []
    var passageParts: [ReaderPassagePart] = []
    var oeb: ReaderOEBPage? = nil
    var sourceStamp: LegacyGraphicSourceStamp? = nil
}

/// New application state. Only the read-only format services cross the prototype boundary.
@MainActor @Observable final class ReaderSession: Identifiable {
    typealias Loader = @Sendable (LibraryResource, ReaderDestination) async throws -> ReaderPage
    typealias FindLoader = @Sendable (LibraryResource, ReaderFindRequest) async throws -> ReaderFindMatch?
    let id = UUID()
    private(set) var resource: LibraryResource
    var page: ReaderPage? {
        didSet {
            bibleIndex = ReaderBibleIndex(anchors: page?.content?.anchors ?? [], textLength: page?.text.utf16.count)
            if !bibleIndex.entries.isEmpty { hasObservedBible = true }
        }
    }
    private(set) var hasObservedBible = false
    @ObservationIgnored private var bibleIndex = ReaderBibleIndex(anchors: [])
    var isDictionary: Bool { LibronDictionaryIndex.supports(resource) }
    var dictionaryWord = ""
    func clearDictionaryDefinition() {
        cancel(); page = nil; flowPages = []; dictionaryWord = ""; error = nil
    }
    func showDictionary(_ replacement: LibraryResource, word: String, page result: ReaderPage?) {
        cancel(); resource = replacement; history = []; historyIndex = -1
        flowPages = []; dictionaryWord = word
        if let result { commit(result); error = nil }
        else { page = nil; error = L("No se encontró una definición en este diccionario.") }
        locator = word
    }
    var locator = ""
    var showsContents = false
    var isLoading = false
    var error: String?
    var history: [ReaderDestination] = []
    var historyIndex = -1
    var isMinimized = false
    var isMaximized = false
    var unsnappedFrame: PaneFrame?
    var textScale = 1.0 {
        didSet { if !ReaderZoom.isValid(textScale) { textScale = oldValue } }
    }
    /// Reader zoom is relative to the new comfortable default. Resource styles
    /// and exported documents retain their original point sizes.
    var renderingScale: Double { _ = AppPreferences.shared.readingFont; return ReaderZoom.renderingScale(textScale) }
    var presentationWarnings: [String] = []
    var sourceFontsRevision = 0
    var visibleInterlinearLines: Set<Int>? = nil
    var effectiveInterlinearLines: Set<Int> {
        visibleInterlinearLines ?? Set(page?.interlinearLines.filter(\.visibleByDefault).map(\.ordinal) ?? [])
    }
    func toggleInterlinearLine(_ ordinal: Int) {
        var selected = effectiveInterlinearLines
        if selected.contains(ordinal) { if selected.count > 1 { selected.remove(ordinal) } }
        else { selected.insert(ordinal) }
        visibleInterlinearLines = selected
    }
    var showsLocator = false
    var locatorIsArticle = false
    var parallelSetID: UUID?
    var linkGroup = ReaderLinkGroup.none
    var onReferenceNavigation: ((String) -> Void)?
    var highlights: [ReaderHighlight] = []
    var showsFind = false
    var findQuery = ""
    var findOptions = ReaderFindOptions()
    var findStatus = ReaderFindStatus.idle
    var findFocusRequest = 0
    var onQuickDictionaryLookup: ((String, NSView, NSRect) -> Void)?
    var onDictionaryLookup: ((String) -> Void)?
    var onTextSelection: ((String) -> Void)?
    var selectedRange = NSRange(location: 0, length: 0) {
        didSet {
            guard !isLoading, let text = page?.text, let range = Range(selectedRange, in: text) else { return }
            onTextSelection?(String(text[range]))
        }
    }
    var visibleBibleReference: String?
    var viewportCharacterOffset: Int?
    var selectionRequest = 0
    var flowPages: [ReaderPage] = []
    var flowWarning: String?
    @ObservationIgnored var flowEnabled = false
    @ObservationIgnored var flowTask: Task<Void, Never>?
    @ObservationIgnored var flowGeneration = 0
    @ObservationIgnored var flowEndOrdinal: Int?
    @ObservationIgnored var flowBeginningOrdinal: Int?
    @ObservationIgnored var flowLookahead = 5
    var oebProjectionReady = false
    var frame = PaneFrame(x: 0.02, y: 0.02, width: 0.76, height: 0.87)
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private let findLoader: FindLoader
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var fontTask: Task<Void, Never>?
    @ObservationIgnored private var findTask: Task<Void, Never>?
    @ObservationIgnored private var findGeneration = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored weak var oebWebView: WKWebView?
    @ObservationIgnored private var pendingOEBSelection: (url: URL, fingerprint: String?, selection: NSRange?)?
    init(resource: LibraryResource, loader: @escaping Loader = ReaderSession.read,
         findLoader: @escaping FindLoader = ReaderFindSource.find) {
        self.resource = resource
        self.textScale = AppPreferences.shared.readingScale
        self.loader = loader
        self.findLoader = findLoader
        // Optional source-media fonts must not hold a book read hostage to a
        // filesystem or font-service stall. Repaint if registration finishes.
        fontTask = Task { [weak self, resource] in
            await ReaderResourceFonts.register(near: resource.location)
            guard !Task.isCancelled else { return }
            self?.sourceFontsRevision += 1
        }
    }
    deinit { fontTask?.cancel(); flowTask?.cancel() }
    var canGoBack: Bool { historyIndex > 0 && !isLoading }
    var canGoForward: Bool { historyIndex + 1 < history.count && !isLoading }
    func goBack() { if canGoBack { load(history[historyIndex - 1], historyTarget: historyIndex - 1) } }
    func goForward() { if canGoForward { load(history[historyIndex + 1], historyTarget: historyIndex + 1) } }
    func goToReference() {
        guard !locator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if locatorIsArticle {
            guard let number = Int(locator.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0,
                  number <= (page?.sectionCount ?? 0) else { error = L("Escribe un número de artículo válido."); return }
            load(.init(ordinal: number - 1)); return
        }
        guard let reference = LegacyPassageQuery.navigationInput(locator) else {
            error = L("Escribe una referencia como Génesis 4:1, Gen 4.1 o Gn 4,1. También puedes escribir solo el libro y capítulo."); return
        }
        load(.init(ordinal: page?.destination.ordinal ?? 0, reference: reference.displayReference))
    }
    func readingPositionLabel(language: AppLanguage) -> String {
        guard let page else { return "" }
        let article = page.articlePositionLabel(language: language)
        guard resource.libron?.resourceType == "Biblia" || canSynchronizeBible,
              let reference = currentReference, !reference.isEmpty else { return article }
        return "\(reference) · \(article)"
    }
    var currentReference: String? {
        visibleBibleReference ?? page?.destination.reference ?? bibleReference(at: selectedRange.location)
    }
    func bibleReference(at offset: Int) -> String? {
        _ = page // Keep the computed result dependent on page replacement.
        return bibleIndex.reference(at: offset)
    }
    var canSynchronizeBible: Bool { _ = page; return !bibleIndex.entries.isEmpty }
    var bibleReferences: [String] { _ = page; return bibleIndex.references }
    /// Only actual viewport scroll events enter this path. Text selection is
    /// independent of the reading position and must never move linked panes.
    func observeBiblePosition(_ offset: Int, fromViewport: Bool = false) {
        guard fromViewport, !isLoading, let page, (0...page.text.utf16.count).contains(offset),
              let reference = bibleReference(at: offset) else { return }
        viewportCharacterOffset = fromViewport ? offset : nil
        guard
              LegacyPassageQuery.parse(reference)?.normalizedKey != currentReference.flatMap({ LegacyPassageQuery.sourceReference($0)?.normalizedKey }) else { return }
        visibleBibleReference = reference
        if !locatorIsArticle { locator = reference }
        onReferenceNavigation?(reference)
    }
    func followBibleReference(_ reference: String) {
        guard let query = LegacyPassageQuery.sourceReference(reference) else { return }
        if flowEnabled, bibleIndex.offsets[query.normalizedKey] == nil {
            let candidates = flowPages.filter {
            ReaderBibleIndex(anchors: $0.content?.anchors ?? [], textLength: $0.text.utf16.count).offsets[query.normalizedKey] != nil
            }
            if candidates.count == 1, let buffered = candidates.first {
                selectFlowPage(buffered, selection: .init(location: 0, length: 0))
            } else if candidates.count > 1 {
                load(.init(ordinal: page?.destination.ordinal ?? 0, reference: query.displayReference), propagateReference: false)
                return
            }
        }
        // A sole label may be inherited article context (for example a
        // preface tagged with the first verse). Ask the checked source index
        // rather than treating that context label as an owned verse body.
        if flowEnabled, bibleIndex.references.count == 1 {
            load(.init(ordinal: page?.destination.ordinal ?? 0, reference: query.displayReference), propagateReference: false)
            return
        }
        // An in-page move needs no disk read or additional history entry.
        if let offset = bibleIndex.offsets[query.normalizedKey] {
            cancel(); error = nil
            viewportCharacterOffset = offset
            visibleBibleReference = query.displayReference
            if !locatorIsArticle { locator = query.displayReference }
            selectedRange = NSRange(location: offset, length: 0); selectionRequest += 1
            if flowEnabled { fillReadingFlow() }
        } else {
            load(.init(ordinal: page?.destination.ordinal ?? 0, reference: query.displayReference), propagateReference: false)
        }
    }
    var canGoToPreviousArticle: Bool { !isLoading && (page?.destination.ordinal ?? 0) > 0 }
    var canGoToNextArticle: Bool { !isLoading && page.map { $0.destination.ordinal + 1 < $0.sectionCount } == true }
    func previousArticle() {
        guard canGoToPreviousArticle, let page else { return }
        if let index = page.passagePartIndex, let destination = page.passageDestination(at: index - 1) { load(destination) }
        else { load(.init(ordinal: page.destination.ordinal - 1)) }
    }
    func nextArticle() {
        guard canGoToNextArticle, let page else { return }
        if let index = page.passagePartIndex, let destination = page.passageDestination(at: index + 1) { load(destination) }
        else { load(.init(ordinal: page.destination.ordinal + 1)) }
    }
    func selectHistory(_ index: Int) {
        guard history.indices.contains(index) else { return }
        load(history[index], historyTarget: index)
    }
    func changeLocatorMode(_ article: Bool) {
        locatorIsArticle = article
        locator = article ? page.map { String($0.destination.ordinal + 1) } ?? "" : currentReference ?? ""
    }
    var selectedText: String {
        guard let text = page?.text as NSString?, selectedRange.location >= 0, selectedRange.length > 0,
              selectedRange.location <= text.length, selectedRange.length <= text.length - selectedRange.location else { return "" }
        return text.substring(with: selectedRange)
    }
    func showFind() {
        let selected = selectedText
        if !selected.isEmpty && selected.utf16.count <= 512 { findQuery = selected }
        showsFind = true; findFocusRequest += 1
    }
    func hideFind() { showsFind = false; cancelFind() }
    func updateFindQuery(_ query: String) {
        findQuery = query
        if query.isEmpty { cancelFind(); findStatus = .idle }
        else { find(.forward, incremental: true) }
    }
    func updateFindOptions(_ options: ReaderFindOptions) {
        findOptions = options
        if !findQuery.isEmpty { find(.forward, incremental: true) }
    }
    func cancelFind() {
        findGeneration += 1; findTask?.cancel(); findTask = nil
        restorePendingOEBFind()
        if findStatus == .searching { findStatus = .idle }
    }
    func find(_ direction: ReaderFindDirection, incremental: Bool = false) {
        cancelFind()
        guard let page, !findQuery.isEmpty else { return }
        generation += 1; task?.cancel(); task = nil; isLoading = false
        // Starting a Find replaces any pending navigation. A failed search leaves
        // the previously committed page, text selection and viewport untouched.
        let token = findGeneration
        let position = direction == .forward && !incremental ? NSMaxRange(selectedRange) : selectedRange.location
        let request = ReaderFindRequest(query: findQuery, ordinal: page.destination.ordinal, position: position,
                                        direction: direction, options: findOptions,
                                        oebViewport: page.oeb == nil ? nil : .init(width: Double(oebWebView?.bounds.width ?? 760), zoom: renderingScale))
        findStatus = .searching; error = nil
        findTask = Task { [weak self, resource, findLoader, loader] in
            do {
                if incremental { try await Task.sleep(for: .milliseconds(100)) }
                let match = try await findLoader(resource, request)
                guard let self, token == self.findGeneration, !Task.isCancelled else { return }
                guard let match else { self.findStatus = .notFound; return }
                var result: ReaderPage
                if self.page?.destination.ordinal == match.ordinal, let current = self.page { result = current }
                else { result = try await loader(resource, .init(ordinal: match.ordinal)) }
                guard token == self.findGeneration, !Task.isCancelled else { return }
                let sameVisibleOEB = result.oeb != nil && self.oebProjectionReady && self.page?.destination.ordinal == match.ordinal
                if let oeb = result.oeb, !sameVisibleOEB {
                    guard let projection = match.oebProjection,
                          projection.path.lowercased() == oeb.book.path(for: oeb.url)?.lowercased() else { throw LibronixBookError.sourceChanged }
                    result.text = projection.text
                }
                guard LibrarySearchService.textFingerprint(result.text) == match.fingerprint,
                      match.range.location >= 0, match.range.length > 0,
                      match.range.location <= result.text.utf16.count,
                      match.range.length <= result.text.utf16.count - match.range.location,
                      Range(match.range, in: result.text) != nil else { throw LegacyIndicesError.sourceChanged }
                if result.oeb != nil {
                    if sameVisibleOEB {
                        self.selectedRange = match.range; self.viewportCharacterOffset = match.range.location; self.selectionRequest += 1
                        self.findStatus = .found(wrapped: match.wrapped)
                    } else if let previous = self.page {
                        self.pendingOEBFind = .init(previous: previous, selection: self.selectedRange,
                            locator: self.locator, ready: self.oebProjectionReady, target: result.oeb!.id, match: match, generation: token)
                        self.pendingOEBSelection = nil
                        self.page = result; self.oebProjectionReady = false
                        self.locator = self.locatorIsArticle ? String(result.destination.ordinal + 1) : result.destination.reference ?? ""
                        self.selectedRange = NSRange(location: 0, length: 0); self.selectionRequest += 1
                        // The visible DOM must agree before history/selection commit.
                        self.findStatus = .searching
                    }
                } else {
                    self.commit(result)
                    self.selectedRange = match.range; self.viewportCharacterOffset = match.range.location; self.selectionRequest += 1
                    self.observeBiblePosition(match.range.location)
                    self.findStatus = .found(wrapped: match.wrapped)
                }
            } catch {
                guard let self, token == self.findGeneration, !Task.isCancelled else { return }
                self.findStatus = .failed(error.localizedDescription)
            }
        }
    }
    func cancel() {
        flowGeneration += 1; flowTask?.cancel(); flowTask = nil
        generation += 1; task?.cancel(); task = nil; isLoading = false; pendingOEBSelection = nil; cancelFind()
    }
    func readForFlow(_ destination: ReaderDestination) async throws -> ReaderPage { try await loader(resource, destination) }
    private func commit(_ result: ReaderPage, historyTarget: Int? = nil) {
        oebProjectionReady = false; pendingOEBSelection = nil; pendingOEBFind = nil
        page = result; locator = locatorIsArticle ? String(result.destination.ordinal + 1) : result.destination.reference ?? ""
        flowPages = [result]; flowWarning = nil; flowEndOrdinal = nil; flowBeginningOrdinal = nil; flowLookahead = 5
        selectedRange = result.selection ?? NSRange(location: 0, length: 0); selectionRequest += 1
        viewportCharacterOffset = result.oeb == nil ? selectedRange.location : nil
        visibleBibleReference = result.destination.reference.flatMap { LegacyPassageQuery.sourceReference($0)?.displayReference }
            ?? bibleReference(at: selectedRange.location)
        if !locatorIsArticle, let reference = visibleBibleReference { locator = reference }
        if let historyTarget { historyIndex = historyTarget }
        else if history.last != result.destination || historyIndex != history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
            history.append(result.destination); historyIndex = history.count - 1
        }
    }
    func load(_ destination: ReaderDestination, historyTarget: Int? = nil, propagateReference: Bool = true,
              selection: NSRange? = nil, expectedFingerprint: String? = nil, viewportOffset: Int? = nil) {
        cancel()
        let token = generation
        isLoading = true; error = nil
        task = Task { [weak self, resource, loader] in
            do {
                let result = try await loader(resource, destination)
                guard let self, token == self.generation, !Task.isCancelled else { return }
                if result.oeb == nil {
                    if let expectedFingerprint, LibrarySearchService.textFingerprint(result.text) != expectedFingerprint { throw LegacyIndicesError.sourceChanged }
                    if let selection, Range(selection, in: result.text) == nil { throw LegacyIndicesError.sourceChanged }
                }
                self.commit(result, historyTarget: historyTarget)
                if let oeb = result.oeb { self.pendingOEBSelection = (oeb.url, expectedFingerprint, selection) }
                else if let selection {
                    self.selectedRange = selection; self.viewportCharacterOffset = selection.location; self.selectionRequest += 1
                }
                if result.oeb == nil {
                    if let viewportOffset, (0...result.text.utf16.count).contains(viewportOffset) { self.viewportCharacterOffset = viewportOffset }
                    self.visibleBibleReference = self.bibleReference(at: self.viewportCharacterOffset ?? self.selectedRange.location)
                    if !self.locatorIsArticle, let reference = self.visibleBibleReference { self.locator = reference }
                }
                self.isLoading = false
                if self.flowEnabled { self.fillReadingFlow() }
                if propagateReference, result.oeb == nil, let reference = self.currentReference { self.onReferenceNavigation?(reference) }
            } catch {
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.isLoading = false
            }
        }
    }
    /// Resolve against the replacement resource before changing the visible book.
    /// Physical article offsets and history never cross edition boundaries.
    func changeBibleVersion(to replacement: LibraryResource, reference: String,
                            onCommit: @escaping () -> Void = {}) {
        changeBibleVersion(candidates: [replacement], reference: reference, onCommit: onCommit)
    }
    func changeBibleVersion(candidates: [LibraryResource], reference: String, onCommit: @escaping () -> Void = {}) {
        guard !isLoading, candidates.contains(where: { $0.id != resource.id }) else { return }
        let originalID = resource.id
        cancel(); let token = generation
        isLoading = true; error = nil
        task = Task { [weak self, loader] in
            do {
                var resolved: (LibraryResource, ReaderPage)?
                for candidate in candidates where candidate.id != originalID {
                    try Task.checkCancellation()
                    do {
                        let page = try await loader(candidate, .init(ordinal: 0, reference: reference))
                        let index = ReaderBibleIndex(anchors: page.content?.anchors ?? [], textLength: page.text.utf16.count)
                        if let query = LegacyPassageQuery.sourceReference(reference), index.offsets[query.normalizedKey] != nil {
                            resolved = (candidate, page); break
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { continue }
                }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                guard let (replacement, result) = resolved else { throw RebuildError.referenceNotFound }
                self.resource = replacement
                self.history = []; self.historyIndex = -1
                self.hasObservedBible = false; self.visibleInterlinearLines = nil
                self.presentationWarnings = []; self.findStatus = .idle
                self.commit(result)
                self.isLoading = false
                self.fontTask?.cancel()
                self.fontTask = Task { [weak self] in
                    await ReaderResourceFonts.register(near: replacement.location)
                    guard !Task.isCancelled else { return }; self?.sourceFontsRevision += 1
                }
                onCommit()
                if self.flowEnabled { self.fillReadingFlow() }
                // Edition replacement does not navigate other linked windows.
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.isLoading = false
            }
        }
    }
    private struct PendingOEBFind {
        let previous: ReaderPage
        let selection: NSRange
        let locator: String
        let ready: Bool
        let target: UUID
        let match: ReaderFindMatch
        let generation: Int
    }
    @ObservationIgnored private var pendingOEBFind: PendingOEBFind?
    var committedPage: ReaderPage? { pendingOEBFind?.previous ?? page }
    var committedSelection: NSRange { pendingOEBFind?.selection ?? selectedRange }
    var committedLocator: String { pendingOEBFind?.locator ?? locator }
    var committedOEBProjectionReady: Bool { pendingOEBFind?.ready ?? oebProjectionReady }
    private func restorePendingOEBFind() {
        guard let pending = pendingOEBFind else { return }
        pendingOEBFind = nil
        if page?.oeb?.id == pending.target {
            page = pending.previous; selectedRange = pending.selection; locator = pending.locator
            oebProjectionReady = pending.ready; selectionRequest += 1
        }
    }
    func rejectOEBProjection(_ error: Error, pageID: UUID?) {
        guard page?.oeb?.id == pageID else { return }
        if pendingOEBFind != nil {
            restorePendingOEBFind(); findStatus = .failed(error.localizedDescription)
        }
        self.error = error.localizedDescription
    }
    func acceptOEBProjection(_ text: String, at url: URL, initialOffset: Int? = nil) throws {
        guard page?.oeb?.url == url else { throw LibronixBookError.sourceChanged }
        if let pending = pendingOEBFind {
            do {
                guard pending.generation == findGeneration, pending.target == page?.oeb?.id,
                      LibrarySearchService.textFingerprint(text) == pending.match.fingerprint,
                      Range(pending.match.range, in: text) != nil else { throw LibronixBookError.sourceChanged }
                try page?.oeb?.book.verifySource()
                var result = page!; result.text = text
                pendingOEBFind = nil; commit(result); oebProjectionReady = true
                selectedRange = pending.match.range; selectionRequest += 1
                findStatus = .found(wrapped: pending.match.wrapped)
            } catch {
                restorePendingOEBFind(); findStatus = .failed(error.localizedDescription); throw error
            }
            return
        }
        page?.text = text; oebProjectionReady = true
        if let pending = pendingOEBSelection, pending.url == url {
            pendingOEBSelection = nil
            if let fingerprint = pending.fingerprint, LibrarySearchService.textFingerprint(text) != fingerprint { throw LibronixBookError.sourceChanged }
            if let range = pending.selection {
                guard Range(range, in: text) != nil else { throw LibronixBookError.sourceChanged }
                selectedRange = range; selectionRequest += 1
                return
            }
        }
        if selectedRange.length == 0, let initialOffset, (0...text.utf16.count).contains(initialOffset) {
            selectedRange = NSRange(location: initialOffset, length: 0)
        }
    }
    nonisolated static func read(_ resource: LibraryResource, _ requested: ReaderDestination) async throws -> ReaderPage {
        if let edition = requested.requiredEdition, resource.location.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(edition) != .orderedSame { throw RebuildError.referenceEditionUnavailable(edition) }
        if LibronNativeReader.location(resource) != nil { return try await LibronNativeReader.shared.read(resource,requested) }
        return try await readOriginal(resource,requested)
    }
    nonisolated static func readOriginal(_ resource: LibraryResource, _ requested: ReaderDestination) async throws -> ReaderPage {
        if let edition = requested.requiredEdition,
           resource.location.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(edition) != .orderedSame {
            throw RebuildError.referenceEditionUnavailable(edition)
        }
        if resource.format == .libronDictionary {
            let source = try LibronDictionaryDatabase.page(resource.location, ordinal: requested.ordinal)
            let content = LegacySectionContent.imported(text: source.body, ordinal: source.ordinal, anchors: [], rtf: nil)
            return ReaderPage(destination: .init(ordinal: source.ordinal), text: source.body, sectionCount: source.count, content: content)
        }
        if resource.format == .eSwordSQLite { return try await ESwordReader.read(resource, requested) }
        if resource.format == .epub { return try await EPUBReader.read(resource, requested) }
        if resource.format == .libronixOEB {
            let book = try await LibronixOEBService.shared.prepare(resource.location)
            var ordinal = requested.ordinal
            var fragment = requested.reference
            if let reference = requested.reference,
               let article = book.directory.articles.first(where: { $0.fragment == reference || $0.title.localizedCaseInsensitiveCompare(reference) == .orderedSame || $0.path.lowercased() == reference.lowercased() }) {
                ordinal = article.ordinal; fragment = article.fragment
            }
            guard book.directory.articles.indices.contains(ordinal) else { throw RebuildError.referenceNotFound }
            let article = book.directory.articles[ordinal]
            fragment = fragment ?? article.fragment
            if let fragment, !fragment.isEmpty, fragment != article.fragment {
                guard let path = book.path(for: book.url(path: article.path)), let data = book.members[path],
                      let html = String(data: data, encoding: .utf8) else { throw RebuildError.referenceNotFound }
                let escaped = NSRegularExpression.escapedPattern(for: fragment)
                let pattern = "(?i:\\b(?:id|name)\\s*=\\s*)(?:\"" + escaped + "\"|'" + escaped + "'|" + escaped + "(?=[\\s>]))"
                guard html.range(of: pattern, options: [.regularExpression]) != nil else { throw RebuildError.referenceNotFound }
            }
            return ReaderPage(destination: .init(ordinal: ordinal, reference: fragment), text: "", sectionCount: book.directory.articles.count,
                entries: book.directory.articles.map { .init(id: $0.ordinal, ordinal: $0.ordinal, title: $0.title, depth: $0.depth) },
                oeb: .init(book: book, url: book.url(path: article.path, fragment: fragment)))
        }
        if resource.format == .libronixLLS {
            let before = try LegacyGraphicsService.fileStamp(resource.location)
            let inner = try await LibronixBookService.shared.prepare(resource)
            var page = try await readLegacy(inner, requested, allowUnavailableIndexBlocks: true)
            page.interlinearLines = try await LibronixBookService.shared.metadata(resource).interlinearLines
            guard try LegacyGraphicsService.fileStamp(resource.location) == before else { throw LibronixBookError.sourceChanged }
            page.sourceStamp = before
            return page
        }
        guard resource.format == .legacyLSF else {
            throw RebuildError.unsupportedFormat
        }
        return try await readLegacy(resource, requested)
    }
    nonisolated private static func readLegacy(_ resource: LibraryResource, _ requested: ReaderDestination,
                                               allowUnavailableIndexBlocks: Bool = false) async throws -> ReaderPage {
        let service = LegacyContentService()
        let sourceStamp = try LegacyGraphicsService.fileStamp(resource.location)
        let index = try await service.inspect(resource.location)
        var destination = requested
        var selection: NSRange?
        var passageParts: [ReaderPassagePart] = []
        if let reference = requested.reference {
            let resolution = try await service.resolvePassage(resource.location, indexURL: resource.indexLocation, reference: reference,
                                                               allowUnavailableIndexBlocks: allowUnavailableIndexBlocks)
            guard let match = resolution.match else {
                if !resolution.exhaustedCandidates { throw RebuildError.referenceSearchIncomplete }
                throw RebuildError.referenceNotFound
            }
            destination = .init(ordinal: match.sectionOrdinal, reference: LegacyPassageQuery.sourceReference(match.observedReference)?.displayReference ?? match.observedReference)
            selection = NSRange(location: match.startCharacterOffset, length: match.endCharacterOffsetExclusive - match.startCharacterOffset)
            if let end = requested.endReference {
                let ending = try await service.resolvePassage(resource.location, indexURL: resource.indexLocation, reference: end,
                    allowUnavailableIndexBlocks: allowUnavailableIndexBlocks)
                guard let last = ending.match else { throw RebuildError.referenceNotFound }
                let beginning: LegacyReferenceMatch
                if let passageStart = requested.passageStartReference {
                    let first = try await service.resolvePassage(resource.location, indexURL: resource.indexLocation, reference: passageStart,
                        allowUnavailableIndexBlocks: allowUnavailableIndexBlocks)
                    guard let firstMatch = first.match else { throw RebuildError.referenceNotFound }
                    beginning = firstMatch
                } else { beginning = match }
                passageParts = try await ReaderPassagePartSource.read(resource.location, service: service, start: beginning, end: last)
                guard let part = passageParts.first(where: { $0.ordinal == match.sectionOrdinal }) else { throw RebuildError.invalidPassagePart }
                destination.reference = part.reference
                destination.passageStartReference = LegacyPassageQuery.sourceReference(beginning.observedReference)?.displayReference ?? beginning.observedReference
                destination.endReference = LegacyPassageQuery.sourceReference(last.observedReference)?.displayReference ?? last.observedReference
                selection = part.selection
            }
        }
        var entries: [ReaderEntry] = []
        var warning: String?
        do {
            let directory = try await service.directory(resource.location, indexURL: resource.indexLocation,
                                                        allowUnavailableIndexBlocks: allowUnavailableIndexBlocks)
            // Untitled internal articles can have opaque CIDX names such as
            // Ge.1 for a footnote. They are not chapter titles. Prefer actual
            // AIDX title strings for Contents, preserving their source order.
            let titled = directory.entries.filter { $0.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            let visible = titled.isEmpty ? directory.entries : titled
            entries = visible.map { .init(id: $0.id, ordinal: $0.sectionOrdinal, title: $0.displayTitle) }
            if requested.prefersContentsStart == true, requested.reference == nil, let first = titled.first {
                destination = .init(ordinal: first.sectionOrdinal)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { warning = "El índice de contenido no está disponible: \(error.localizedDescription)" }
        destination.prefersContentsStart = nil
        destination.requiredEdition = requested.requiredEdition
        let content: LegacySectionContent
        if let retained = passageParts.first(where: { $0.ordinal == destination.ordinal }) { content = retained.content }
        else { content = try await service.read(resource.location, ordinal: destination.ordinal) }
        var inlineLinks: [LegacyInlineLink] = []
        do {
            let resolved = try await service.inlineLinks(resource.location, content: content, indexURL: resource.indexLocation,
                                                         allowUnavailableIndexBlocks: allowUnavailableIndexBlocks)
            inlineLinks = resolved.links
            if resolved.unresolvedAttributedRuns > 0 {
                warning = ([warning].compactMap { $0 } + ["Algunos destinos de enlace todavía no se interpretan: \(resolved.unresolvedAttributedRuns)."])
                    .joined(separator: "\n")
            }
        } catch is CancellationError { throw CancellationError() }
        catch { warning = ([warning].compactMap { $0 } + ["Los enlaces de este artículo no están disponibles: \(error.localizedDescription)"]).joined(separator: "\n") }
        var typography: LegacyTypography?
        do { typography = try await ReaderStyleSource.shared.read(resource.location) }
        catch is CancellationError { throw CancellationError() }
        catch {
            let message = "No se pudieron cargar los estilos: \(error.localizedDescription)"
            warning = [warning, message].compactMap { $0 }.joined(separator: "\n")
        }
        let graphicService = LegacyGraphicsService()
        var graphics: [LegacyGraphicAsset] = [], graphicWarnings: [String] = []
        if passageParts.isEmpty {
            let result = try await graphicService.load(resource.location, graphics: content.graphics, expectedSource: sourceStamp)
            graphics = result.assets; graphicWarnings = result.warnings
        } else {
            var remainingImageBytes = 64 * 1_024 * 1_024
            for position in passageParts.indices {
                try Task.checkCancellation()
                guard remainingImageBytes > 0 else { throw RebuildError.passageReadLimit }
                let result = try await graphicService.load(resource.location, graphics: passageParts[position].content.graphics,
                    expectedSource: sourceStamp, maximumTotalBytes: remainingImageBytes)
                remainingImageBytes -= result.assets.reduce(0) { $0 + $1.data.count }
                passageParts[position].graphics = result.assets
                graphicWarnings += result.warnings
                if passageParts[position].ordinal == destination.ordinal { graphics = result.assets }
            }
        }
        warning = ([warning].compactMap { $0 } + graphicWarnings).joined(separator: "\n")
        guard try LegacyGraphicsService.fileStamp(resource.location) == sourceStamp else { throw LegacyIndicesError.sourceChanged }
        if warning?.isEmpty == true { warning = nil }
        try Task.checkCancellation()
        return ReaderPage(destination: destination, text: content.plainText, sectionCount: index.sections.count,
                          entries: entries, selection: selection, warning: warning, content: content, typography: typography,
                          graphics: graphics, inlineLinks: inlineLinks, passageParts: passageParts, sourceStamp: sourceStamp)
    }
}

/// The style table is resource-wide. Read it away from the UI actor and retain
/// only a bounded cache, invalidated when the source file changes.
actor ReaderStyleSource {
    static let shared = ReaderStyleSource()
    private struct Entry {
        let stamp: LegacyGraphicSourceStamp
        let value: LegacyTypography
    }
    private var entries: [URL: Entry] = [:]
    func read(_ url: URL) throws -> LegacyTypography {
        try Task.checkCancellation()
        let before = try LegacyGraphicsService.fileStamp(url)
        if let cached = entries[url], cached.stamp == before { return cached.value }
        let value = try LegacyTypographyReader.inspect(lsfURL: url)
        try Task.checkCancellation()
        guard try LegacyGraphicsService.fileStamp(url) == before else { throw LegacyIndicesError.sourceChanged }
        if entries.count >= 8 { entries.removeAll() }
        entries[url] = Entry(stamp: before, value: value)
        return value
    }
}

