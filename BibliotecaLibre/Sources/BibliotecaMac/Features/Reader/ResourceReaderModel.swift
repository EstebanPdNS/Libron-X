import AppKit
import Foundation
import ImageIO
import LibronixCore
import Observation

enum ReaderTab: String, Identifiable, CaseIterable {
    case information, preview
    var id: Self { self }
    var title: String { self == .information ? "Información" : "Lectura" }
}

/// One independent reader per window. Completed destinations are the only
/// values committed to history and persisted as reading positions.
@MainActor @Observable final class ResourceReaderModel {
    var tab: ReaderTab = .information
    var sections: [LegacySectionDescriptor] = []
    var directory: LegacyArticleDirectory?
    var articleFilter = ""
    var showsContents = false
    var ordinal = 0
    var sectionInput = "1"
    var locatorInput = ""
    var content: LegacySectionContent?
    var graphicAssets: [ReaderGraphic] = []
    var graphicWarnings: [String] = []
    var isLoading = false
    var errorMessage: String?
    var navigationMessage: String?
    var directoryWarning: String?
    var highlightRange: NSRange?
    var findText = ""
    var findMessage: String?
    var findFocusRequest = 0
    var locatorFocusRequest = 0
    var history = ReadingHistory()
    var savedBookmarks: [Int] = []
    var committedReference: String?
    var navigationOffset: Int?
    var selectedTextRange: SearchTextRange?
    @ObservationIgnored var didNavigate: ((ReaderLocation, Bool) -> Void)?
    @ObservationIgnored private let service = LegacyContentService()
    @ObservationIgnored private let graphicsService = LegacyGraphicsService()
    @ObservationIgnored private var resource: LibraryResource?
    @ObservationIgnored private var request = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    var canGoBack: Bool { history.previous != nil && !isLoading }
    var canGoForward: Bool { history.next != nil && !isLoading }
    var isBookmarked: Bool { savedBookmarks.contains(ordinal) }
    var currentEntry: LegacyArticleDirectoryEntry? { directory?.entries.first { $0.sectionOrdinal == ordinal && $0.title != nil } }
    var currentTitle: String { currentEntry?.displayTitle ?? "Artículo \(ordinal + 1)" }
    var currentLocation: ReaderLocation? {
        guard let resource, let content else { return nil }
        return ReaderLocation(resourceID: resource.id, legacyIdentifier: resource.legacyIdentifier,
            format: resource.format, sectionOrdinal: ordinal, reference: committedReference,
            textFingerprint: LibrarySearchService.textFingerprint(content.plainText), characterOffset: navigationOffset)
    }
    var visibleEntries: [LegacyArticleDirectoryEntry] {
        let entries = directory?.entries ?? []
        guard !articleFilter.isEmpty else { return entries }
        return entries.filter { ($0.displayTitle + " " + ($0.positionLabel ?? "")).localizedStandardContains(articleFilter) }
    }
    private var positionKey: String? { resource.map { "readerPosition.v1." + $0.id } }
    private var bookmarksKey: String? { resource.map { "readerBookmarks.v1." + $0.id } }

    func cancelPendingRead() { task?.cancel(); request += 1; isLoading = false }
    func openSearchResult(_ result: LibrarySearchResult, resource next: LibraryResource) {
        tab = .preview
        let range = result.hits.first?.range.nsRange ?? result.verseRange?.nsRange
        if resource == next { load(result.sectionOrdinal, passageRange: range, expectedTextFingerprint: result.decodedTextSHA256) }
        else { open(next, initialSection: result.sectionOrdinal, initialRange: range, expectedTextFingerprint: result.decodedTextSHA256) }
    }
    func open(_ next: LibraryResource, initialSection: Int? = nil, initialRange: NSRange? = nil, expectedTextFingerprint: String? = nil,
              initialReference: String? = nil, initialHistory: ReadingHistory? = nil) {
        guard resource != next else { return }
        cancelPendingRead()
        let generation = request
        resource = next
        sections = []; directory = nil; content = nil; graphicAssets = []; graphicWarnings = []
        ordinal = 0; sectionInput = "1"; locatorInput = ""
        history = ReadingHistory(); highlightRange = nil; committedReference = nil; navigationOffset = nil; selectedTextRange = nil
        errorMessage = nil; navigationMessage = nil; directoryWarning = nil
        articleFilter = ""; findText = ""; findMessage = nil
        savedBookmarks = bookmarksKey.flatMap { UserDefaults.standard.array(forKey: $0) as? [Int] } ?? []
        guard next.format == .legacyLSF else { return }
        isLoading = true
        task = Task { [weak self, service] in
            do {
                let index = try await service.inspect(next.location)
                let directory: LegacyArticleDirectory?
                var warning: String?
                do { directory = try await service.directory(next.location, indexURL: next.indexLocation) }
                catch is CancellationError { throw CancellationError() }
                catch { directory = nil; warning = "El índice de artículos no pudo abrirse. Puedes recorrer las secciones físicas. \(error.localizedDescription)" }
                try Task.checkCancellation()
                guard let self, self.request == generation else { return }
                self.sections = index.sections; self.directory = directory; self.directoryWarning = warning
                let stored = self.positionKey.map { UserDefaults.standard.integer(forKey: $0) } ?? 0
                let initial = initialSection ?? (index.sections.indices.contains(stored) && stored > 0 ? stored
                    : directory?.entries.first(where: { $0.title != nil })?.sectionOrdinal ?? 0)
                self.isLoading = false
                let validHistory = initialHistory.flatMap { value in value.sections.allSatisfy(index.sections.indices.contains) ? value : nil }
                self.load(initial, historyDestination: validHistory, passageRange: initialRange,
                    expectedTextFingerprint: expectedTextFingerprint, reference: initialReference, notifyLinks: false)
            } catch is CancellationError { }
            catch {
                guard let self, self.request == generation else { return }
                self.errorMessage = error.localizedDescription; self.isLoading = false
            }
        }
    }

    func load(_ next: Int, historyDestination: ReadingHistory? = nil, passageRange: NSRange? = nil, expectedTextFingerprint: String? = nil,
              reference: String? = nil, notifyLinks: Bool = true) {
        guard let resource, sections.indices.contains(next) else {
            sectionInput = "\(ordinal + 1)"; navigationMessage = "El número de artículo está fuera del recurso."; return
        }
        task?.cancel(); request += 1
        let generation = request
        isLoading = true; errorMessage = nil; navigationMessage = nil
        task = Task { [weak self, service, graphicsService] in
            do {
                let source = try LegacyGraphicsService.fileStamp(resource.location)
                let candidate = try await service.read(resource.location, ordinal: next)
                if let passageRange {
                    let count = candidate.plainText.utf16.count
                    guard passageRange.location >= 0, passageRange.length >= 0,
                          passageRange.location <= count, passageRange.length <= count - passageRange.location,
                          Range(passageRange, in: candidate.plainText) != nil else { throw LegacyIndicesError.invalidReferenceRange }
                }
                if let expectedTextFingerprint, LibrarySearchService.textFingerprint(candidate.plainText) != expectedTextFingerprint {
                    throw LegacyIndicesError.sourceChanged
                }
                let loaded = try await graphicsService.load(resource.location, graphics: candidate.graphics, expectedSource: source)
                try Task.checkCancellation()
                guard let self, self.request == generation else { return }
                var assets: [ReaderGraphic] = [], warnings = loaded.warnings
                for asset in loaded.assets {
                    guard let imageSource = CGImageSourceCreateWithData(asset.data as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                          width.doubleValue > 0, height.doubleValue > 0,
                          width.doubleValue * height.doubleValue <= 64_000_000,
                          NSImage(data: asset.data) != nil else {
                        warnings.append("La imagen \(asset.name) se recuperó, pero su formato o tamaño todavía no se puede representar.")
                        continue
                    }
                    assets.append(.init(offset: asset.graphic.objectCharacterOffset, data: asset.data, sha256: asset.sha256))
                }
                self.content = candidate; self.ordinal = next; self.sectionInput = "\(next + 1)"
                self.selectedTextRange = nil
                self.graphicAssets = assets; self.graphicWarnings = warnings
                self.highlightRange = passageRange; self.findMessage = nil
                self.committedReference = reference
                self.navigationOffset = passageRange?.location
                if let reference { self.locatorInput = reference }
                if let historyDestination { self.history = historyDestination }
                else { self.history.visit(next) }
                if let key = self.positionKey { UserDefaults.standard.set(next, forKey: key) }
                self.isLoading = false
                if let location = self.currentLocation { self.didNavigate?(location, notifyLinks) }
            } catch is CancellationError { }
            catch {
                guard let self, self.request == generation else { return }
                // Keep the last readable article and history after an unsuccessful move.
                self.errorMessage = error.localizedDescription; self.isLoading = false
                self.sectionInput = "\(self.ordinal + 1)"
            }
        }
    }

    func submitSection() {
        guard let number = Int(sectionInput.trimmingCharacters(in: .whitespaces)), number > 0 else {
            sectionInput = "\(ordinal + 1)"; navigationMessage = "Escribe un número de artículo válido."; return
        }
        load(number - 1)
    }
    func openEntry(_ entry: LegacyArticleDirectoryEntry) { tab = .preview; load(entry.sectionOrdinal) }
    func goBack() { var next = history; if let section = next.back() { load(section, historyDestination: next) } }
    func goForward() { var next = history; if let section = next.forward() { load(section, historyDestination: next) } }
    func toggleBookmark() {
        guard content != nil, let key = bookmarksKey else { return }
        if isBookmarked { savedBookmarks.removeAll { $0 == ordinal } }
        else { savedBookmarks.append(ordinal); savedBookmarks.sort() }
        UserDefaults.standard.set(savedBookmarks, forKey: key)
    }

    func submitLocator() { navigateToReference(locatorInput) }
    func navigateToReference(_ inputReference: String, notifyLinks: Bool = true) {
        guard let resource, !inputReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let input = inputReference.trimmingCharacters(in: .whitespacesAndNewlines)
        // Positions such as Page 15 are matched exactly to CIDX source labels.
        if let entry = directory?.entries.first(where: { $0.positionLabel?.compare(input, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            openEntry(entry); return
        }
        task?.cancel(); request += 1
        let generation = request
        isLoading = true; navigationMessage = nil; errorMessage = nil
        task = Task { [weak self, service] in
            do {
                if input.hasPrefix("LLS-A") {
                    guard let identity = LegacyNumericResourceID.fromBKIDHex(resource.legacyIdentifier) else { throw LegacyLocatorError.resourceMismatch }
                    let resolved = try await service.resolveArticleLocator(resource, originalResourceID: identity.identifier, position: input)
                    try Task.checkCancellation()
                    guard let self, self.request == generation else { return }
                    self.isLoading = false
                    self.load(resolved.location.sectionOrdinal, passageRange: resolved.range.nsRange,
                        expectedTextFingerprint: resolved.location.textFingerprint, reference: resolved.location.reference, notifyLinks: notifyLinks)
                    return
                }
                let resolution = try await service.resolvePassage(resource.location, indexURL: resource.indexLocation,
                                                                  reference: input, maximumCandidates: 256)
                try Task.checkCancellation()
                guard let self, self.request == generation else { return }
                self.isLoading = false
                guard let match = resolution.match else {
                    self.navigationMessage = !resolution.diagnostics.isEmpty
                        ? "No se pudo confirmar el pasaje: hay artículos incompatibles en los candidatos."
                        : resolution.exhaustedCandidates ? "Este pasaje no se encontró en las anclas del recurso."
                        : "La búsqueda del pasaje llegó al límite de candidatos; el resultado es incompleto."
                    return
                }
                self.load(match.sectionOrdinal, passageRange: NSRange(location: match.startCharacterOffset,
                    length: match.endCharacterOffsetExclusive - match.startCharacterOffset), reference: input, notifyLinks: notifyLinks)
            } catch is CancellationError { }
            catch {
                guard let self, self.request == generation else { return }
                self.navigationMessage = error.localizedDescription; self.isLoading = false
            }
        }
    }

    func findNext() { find(backwards: false) }
    func findPrevious() { find(backwards: true) }
    func findFromBeginning() { find(backwards: false, fromBeginning: true) }
    private func find(backwards: Bool, fromBeginning: Bool = false) {
        guard let content, !findText.isEmpty else { highlightRange = nil; findMessage = nil; return }
        let text = content.plainText as NSString
        let start = fromBeginning ? 0 : min(text.length, (highlightRange?.location ?? -1) + (highlightRange?.length ?? 1))
        let end = min(text.length, max(0, highlightRange?.location ?? text.length))
        let scope = backwards ? NSRange(location: 0, length: end) : NSRange(location: start, length: text.length - start)
        let options: NSString.CompareOptions = backwards ? [.caseInsensitive, .diacriticInsensitive, .backwards] : [.caseInsensitive, .diacriticInsensitive]
        var range = text.range(of: findText, options: options, range: scope)
        if range.location == NSNotFound { range = text.range(of: findText, options: options) }
        // Original GUIAGRK Find keeps its previous selection on a failed query.
        guard range.location != NSNotFound else { findMessage = "Sin coincidencias en este artículo."; return }
        highlightRange = range; findMessage = nil
    }
    func recordSelection(_ range: NSRange, text: String) {
        guard text == content?.plainText, range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count, range.length <= text.utf16.count - range.location else { return }
        selectedTextRange = SearchTextRange(location: range.location, length: range.length)
    }
}
