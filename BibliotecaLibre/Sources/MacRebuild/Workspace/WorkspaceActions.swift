import AppKit
import LibronixCore

enum WorkspaceTool: String, Identifiable { case search, referenceSearch, annotationSearch, documents, favorites, information, resources, topics, bibleCopy, windows, parallelSets, keyLinks, associations, associationLinks, bibliography, editions, passageComparison, readingPlans, passageGuide, prayerJournal, scriptureMemory, studyAssessments, wordSearch, commandPalette, biblicalMeasures, researchInbox, transliteration, libraryHealth
    var id: String { rawValue }
}
struct ReaderHighlight: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var resourceID: String
    var ordinal: Int
    var fingerprint: String
    var range: NSRange
    var color: String
}

@MainActor extension StudyWorkspace {
    func connect(_ reader: ReaderSession) {
        reader.onDictionaryLookup = { [weak self] word in
            guard let self else { return }; self.dictionary.show(word, workspace: self)
        }
        reader.onQuickDictionaryLookup = { [weak self, weak reader] word, view, rect in
            guard let self, let reader else { return }
            self.activate(reader); self.dictionary.show(word, workspace: self, anchor: view, rect: rect)
        }
        reader.onTextSelection = { [weak self, weak reader] text in
            guard let self, reader?.isDictionary == false else { return }
            self.dictionary.selectionChanged(text, workspace: self)
        }
        reader.highlights = personal.highlights.filter { $0.resourceID == reader.resource.id }
        reader.onReadingPositionChange = { [weak self, weak reader] reference in
            guard let self, let reader else { return }
            if self.activeID == reader.id, reader.canSynchronizeBible {
                for follower in self.readers where follower.commentaryFollowsActiveBible { follower.commentarySourceID = reader.id }
            }
            self.updateCommentaryFollowers(from: reader, reference: reader.commentaryViewportReference ?? reference)
        }
        reader.onReferenceNavigation = { [weak self, weak reader] reference in
            guard let self, let reader, reader.linkGroup != .none else { return }
            for other in self.readers where other !== reader && other.linkGroup == reader.linkGroup {
                other.followBibleReference(reference)
            }
        }
    }
    @discardableResult func duplicate(_ reader: ReaderSession) -> ReaderSession {
        let copy = open(reader.resource, startReading: false)
        copy.page = reader.committedPage; copy.locator = reader.committedLocator
        copy.history = reader.history; copy.historyIndex = reader.historyIndex
        copy.showsContents = reader.showsContents; copy.showsLocator = reader.showsLocator
        copy.locatorIsArticle = reader.locatorIsArticle; copy.textScale = reader.textScale
        copy.showsStrongNumbers = reader.showsStrongNumbers
        copy.parallelSetID = reader.parallelSetID
        copy.commentaryResourceID = reader.commentaryResourceID
        copy.commentaryFollowsActiveBible = reader.commentaryFollowsActiveBible
        copy.commentaryReference = reader.commentaryReference
        copy.followsCommentary = false
        copy.visibleInterlinearLines = reader.visibleInterlinearLines
        copy.selectedRange = reader.committedSelection; copy.selectionRequest += 1
        copy.visibleBibleReference = reader.visibleBibleReference; copy.viewportCharacterOffset = reader.viewportCharacterOffset
        return copy
    }
    func cycleReader(backwards: Bool = false) {
        let ordered = orderedReaders
        guard !ordered.isEmpty else { return }
        guard let index = ordered.firstIndex(where: { $0.id == activeID }) else {
            activate(backwards ? ordered[ordered.count - 1] : ordered[0]); return
        }
        activate(ordered[(index + (backwards ? ordered.count - 1 : 1)) % ordered.count])
    }
    func openSelectedLibraryResource(_ resource: LibraryResource) {
        let destination = pendingLibraryReference.map { ReaderDestination(ordinal: 0, reference: $0) }
        pendingLibraryReference = nil
        if LibronMetadata.deriving(resource).resourceType == "Comentario bíblico" {
            openCommentary(resource)
            if let reference = destination?.reference, let target = activeReader {
                target.load(.init(ordinal: 0, reference: reference))
            }
        } else { open(resource, destination: destination) }
    }
    func toggleReferenceTarget(_ reader: ReaderSession) {
        setReferenceTarget(referenceTargetID != reader.id, for: reader)
    }
    func setReferenceTarget(_ selected: Bool, for reader: ReaderSession) {
        guard readers.contains(where: { $0 === reader }) else { return }
        if selected { referenceTargetID = reader.id }
        else if referenceTargetID == reader.id { referenceTargetID = nil }
    }
    func clearLinks() { for reader in readers { reader.linkGroup = .none } }
    var bibleReaders: [ReaderSession] { readers.filter(\.canSynchronizeBible) }
    func synchronizeBibles(from reader: ReaderSession? = nil) {
        let candidates = bibleReaders
        guard candidates.count > 1,
              let source = reader ?? activeReader.flatMap({ $0.canSynchronizeBible ? $0 : nil }) ?? candidates.first,
              candidates.contains(where: { $0 === source }), let reference = source.currentReference else { return }
        let used = Set(readers.map(\.linkGroup))
        let group = source.linkGroup != .none ? source.linkGroup : ReaderLinkGroup.allCases.first { $0 != .none && !used.contains($0) } ?? .a
        for candidate in candidates {
            candidate.linkGroup = group
            candidate.followBibleReference(reference)
        }
    }
    func setLinkGroup(_ group: ReaderLinkGroup, for reader: ReaderSession) {
        guard readers.contains(where: { $0 === reader }), reader.linkGroup != group else { return }
        let leader = readers.first { $0 !== reader && $0.linkGroup == group }
        reader.linkGroup = group
        if group != .none, let reference = leader?.currentReference { reader.followBibleReference(reference) }
    }
    var canLinkActiveReader: Bool {
        activeReader.map { $0.canSynchronizeBible || $0.hasObservedBible || $0.linkGroup != .none } ?? false
    }
    func setActiveLinkGroup(_ group: ReaderLinkGroup, selected: Bool) {
        guard let reader = activeReader, canLinkActiveReader else { return }
        if selected { setLinkGroup(group, for: reader) }
        else if group != .none, reader.linkGroup == group { setLinkGroup(.none, for: reader) }
    }
    func setBibleLink(_ linked: Bool, from source: ReaderSession, to target: ReaderSession) {
        guard source !== target, readers.contains(where: { $0 === source }), readers.contains(where: { $0 === target }) else { return }
        if !linked { target.linkGroup = .none; return }
        guard source.canSynchronizeBible, target.canSynchronizeBible, let reference = source.currentReference else { return }
        let used = Set(readers.map(\.linkGroup))
        let group = source.linkGroup != .none ? source.linkGroup : target.linkGroup != .none ? target.linkGroup :
            ReaderLinkGroup.allCases.first { $0 != .none && !used.contains($0) } ?? .a
        source.linkGroup = group; target.linkGroup = group
        source.followBibleReference(reference)
        target.followBibleReference(reference)
    }
    func beginSearch() {
        search.resourceID = activeReader?.resource.id
        activeTool = .search
    }
    func submitToolbarSearch() {
        guard !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        beginSearch()
        search.run(availableResources, documents: personal.documents, namedRanges: personal.namedBibleRanges.ranges, scopeContext: searchScopeContext())
    }
    func addHighlight(_ color: String) {
        guard let reader = activeReader, let page = reader.page, reader.selectedRange.length > 0 else { return }
        let mark = ReaderHighlight(resourceID: reader.resource.id, ordinal: page.destination.ordinal,
            fingerprint: LibrarySearchService.textFingerprint(page.text), range: reader.selectedRange, color: color)
        personal.highlights.append(mark)
        for pane in readers where pane.resource.id == reader.resource.id { pane.highlights.append(mark) }
        savePersonal()
    }
    func eraseHighlight() {
        guard let reader = activeReader, let page = reader.page else { return }
        let removed = Set(personal.highlights.filter { mark in
            mark.resourceID == reader.resource.id && mark.ordinal == page.destination.ordinal &&
            mark.fingerprint == LibrarySearchService.textFingerprint(page.text) &&
            NSIntersectionRange(mark.range, reader.selectedRange).length > 0
        }.map(\.id))
        personal.highlights.removeAll { removed.contains($0.id) }
        for pane in readers { pane.highlights.removeAll { removed.contains($0.id) } }
        savePersonal()
    }
    func addFavorite() {
        guard let reader = activeReader, let page = reader.page else { return }
        let location = ReaderLocation(resourceID: reader.resource.id, legacyIdentifier: reader.resource.legacyIdentifier, format: reader.resource.format,
            sectionOrdinal: page.destination.ordinal, reference: reader.currentReference,
            textFingerprint: LibrarySearchService.textFingerprint(page.text), characterOffset: reader.selectedRange.location)
        do {
            let favorite = LibraryFavorite(title: reader.resource.title + " · " + (reader.currentReference ?? "Artículo \(page.destination.ordinal + 1)"),
                                           kind: .location, location: location)
            try personal.editFavorites { try $0.insert(favorite) }
        } catch { self.error = error.localizedDescription }
    }
    var canCaptureResearchExcerpt: Bool {
        guard let reader = activeReader, !reader.isLoading, let page = reader.page, page.oeb == nil,
              reader.selectedRange.length > 0, reader.selectedRange.length <= 65_536 else { return false }
        return Range(reader.selectedRange, in: page.text) != nil
    }
    func captureResearchExcerpt() {
        guard canCaptureResearchExcerpt, let reader = activeReader, let page = reader.page,
              let range = Range(reader.selectedRange, in: page.text) else { return }
        let location = ReaderLocation(resourceID: reader.resource.id, legacyIdentifier: reader.resource.legacyIdentifier,
            format: reader.resource.format, sectionOrdinal: page.destination.ordinal, reference: page.destination.reference,
            textFingerprint: LibrarySearchService.textFingerprint(page.text), characterOffset: reader.selectedRange.location)
        let excerpt = ResearchExcerpt(sourceTitle: reader.resource.title, text: String(page.text[range]), location: location,
                                     selectionLength: reader.selectedRange.length)
        do { try personal.editResearchInbox { $0.excerpts.insert(excerpt, at: 0) }; activeTool = .researchInbox }
        catch { self.error = L(error.localizedDescription) }
    }
    func openResearchExcerpt(_ excerpt: ResearchExcerpt) {
        guard saveResearchDraftIfNeeded() else { return }
        guard let resource = excerpt.location.resolve(in: resources), let offset = excerpt.location.characterOffset else {
            error = L("El recurso de este extracto no está disponible en la biblioteca abierta."); return
        }
        let reader = open(resource, startReading: false)
        reader.load(.init(ordinal: excerpt.location.sectionOrdinal, reference: excerpt.location.reference),
                    selection: NSRange(location: offset, length: excerpt.selectionLength), expectedFingerprint: excerpt.location.textFingerprint)
        activeTool = nil
    }
    /// Bookmarks are bound to the exact edition and visible UTF-16 position.
    /// Web-backed pages are excluded until their rendered projection is stable.
    var currentBookmarkLocation: ReaderLocation? {
        guard let reader = activeReader, !reader.isLoading, let page = reader.page, page.oeb == nil else { return nil }
        let offset = reader.viewportCharacterOffset ?? reader.selectedRange.location
        guard offset >= 0, Range(NSRange(location: offset, length: 0), in: page.text) != nil else { return nil }
        return ReaderLocation(resourceID: reader.resource.id, legacyIdentifier: reader.resource.legacyIdentifier,
            format: reader.resource.format, sectionOrdinal: page.destination.ordinal, reference: page.destination.reference,
            textFingerprint: LibrarySearchService.textFingerprint(page.text), characterOffset: offset)
    }
    func assignBookmark(_ slot: Int) {
        guard let location = currentBookmarkLocation else { return }
        do { try personal.setBookmark(slot, location: location) }
        catch { self.error = L(error.localizedDescription) }
    }
    func removeBookmark(_ slot: Int) {
        do { try personal.setBookmark(slot, location: nil) }
        catch { self.error = L(error.localizedDescription) }
    }
    func openBookmark(_ slot: Int, loader: ReaderSession.Loader? = nil) {
        guard let location = personal.bookmarks.slots[slot] else { return }
        guard let resource = location.resolve(in: resources) else {
            error = L("El recurso de este marcador no está disponible en la biblioteca abierta."); return
        }
        let reader = open(resource, startReading: false, loader: loader)
        let selection = location.characterOffset.map { NSRange(location: $0, length: 0) }
        reader.load(.init(ordinal: location.sectionOrdinal, reference: location.reference),
                    selection: selection, expectedFingerprint: location.textFingerprint)
        activeTool = nil
    }
    func openFavorite(_ favorite: LibraryFavorite, loader: ReaderSession.Loader? = nil) {
        cancelOriginalFavoriteNavigation()
        if favorite.kind == .legacyCommand, let command = favorite.legacyCommand {
            openOriginalFavorite(command, loader: loader)
            return
        }
        guard let location = favorite.location, let resource = location.resolve(in: resources) else {
            error = L("El recurso de este favorito no está disponible en la biblioteca abierta."); return
        }
        let reader = open(resource, startReading: false, loader: loader)
        let selection = location.characterOffset.map { NSRange(location: $0, length: 0) }
        reader.load(.init(ordinal: location.sectionOrdinal, reference: location.reference),
                    selection: selection, expectedFingerprint: location.textFingerprint)
        activeTool = nil
    }
    func cancelOriginalFavoriteNavigation() {
        originalFavoriteGeneration += 1
        originalFavoriteTask?.cancel()
        originalFavoriteTask = nil
    }
    private func openOriginalFavorite(_ command: String, loader: ReaderSession.Loader?) {
        do {
            let destination = try LegacyJumpDestination.parse(command)
            let matches = resources.filter {
                $0.format == .legacyLSF && LegacyNumericResourceID.fromBKIDHex($0.legacyIdentifier)?.identifier == destination.resourceID
            }
            guard matches.count == 1, let resource = matches.first else {
                error = L(matches.isEmpty ? "El recurso de este favorito no está disponible en la biblioteca abierta." : "Hay varias copias de este recurso. Se conserva el destino hasta confirmar la edición.")
                return
            }
            let generation = originalFavoriteGeneration
            let readerID = activeID, readerGeneration = activeReader?.associationGeneration
            originalFavoriteTask = Task { [weak self] in
                do {
                    let result = try await LegacyContentService().resolveArticleLocator(resource, originalResourceID: destination.resourceID, position: destination.position)
                    try Task.checkCancellation()
                    guard let self, self.originalFavoriteGeneration == generation else { return }
                    self.originalFavoriteTask = nil
                    guard self.activeID == readerID, self.activeReader?.associationGeneration == readerGeneration,
                          self.resources.filter({ $0.format == .legacyLSF && LegacyNumericResourceID.fromBKIDHex($0.legacyIdentifier)?.identifier == destination.resourceID }).count == 1,
                          result.location.resolve(in: self.resources) != nil else { return }
                    let reader = self.open(resource, startReading: false, loader: loader)
                    reader.load(.init(ordinal: result.location.sectionOrdinal, reference: result.location.reference),
                                selection: result.range.nsRange, expectedFingerprint: result.location.textFingerprint)
                    self.activeTool = nil
                } catch is CancellationError { }
                catch {
                    guard let self, self.originalFavoriteGeneration == generation else { return }
                    self.originalFavoriteTask = nil
                    guard self.activeID == readerID, self.activeReader?.associationGeneration == readerGeneration else { return }
                    self.error = L(error.localizedDescription)
                }
            }
        } catch { self.error = L(error.localizedDescription) }
    }
    func savePersonal() {
        do { try personal.save() } catch { self.error = error.localizedDescription }
    }
    func addNoteForSelection(_ reader: ReaderSession) {
        guard let page = reader.page else { return }
        if !personal.documents.contains(where: { $0.kind == .notebook }) { personal.create(.notebook) }
        guard let index = personal.documents.firstIndex(where: { $0.kind == .notebook }) else { return }
        let location = ReaderLocation(resourceID: reader.resource.id, legacyIdentifier: reader.resource.legacyIdentifier, format: reader.resource.format,
            sectionOrdinal: page.destination.ordinal, reference: reader.currentReference,
            textFingerprint: LibrarySearchService.textFingerprint(page.text), characterOffset: reader.selectedRange.location)
        let selection = reader.selectedRange.length > 0 ? SearchTextRange(location: reader.selectedRange.location, length: reader.selectedRange.length) : nil
        var note = StudyNote(title: reader.currentReference ?? "Nota sobre \(reader.resource.title)",
                             anchor: .init(kind: selection == nil ? .nativeReference : .nativeSelection, location: location, selection: selection))
        note.sourceContentType = "text/plain"; note.sourceBody = reader.selectedText
        personal.documents[index].notes.append(note); personal.selectedDocumentID = personal.documents[index].id
        pendingNoteID = note.id
        savePersonal(); activeTool = .documents
    }
    func newNote() {
        if let reader = activeReader, reader.page != nil { addNoteForSelection(reader); return }
        if !personal.documents.contains(where: { $0.kind == .notebook }) { personal.create(.notebook) }
        guard let index = personal.documents.firstIndex(where: { $0.kind == .notebook }) else { return }
        var note = StudyNote(); note.sourceContentType = "text/plain"
        personal.documents[index].notes.append(note); personal.selectedDocumentID = personal.documents[index].id
        pendingNoteID = note.id; savePersonal(); activeTool = .documents
    }
    func openSearchResult(_ result: LibrarySearchResult, scope: WorkspaceSearchScopeSnapshot? = nil, focus: WorkspaceSearchResultFocus = .automatic) {
        do {
            guard focus.isValid(for: result) else { throw LibronixBookError.sourceChanged }
            let resource = try resourceForSearchResult(result, scope: scope)
            let reader = readers.first(where: {
                $0.id == referenceTargetID && $0.resource.id == resource.id && $0.resource.format == resource.format &&
                $0.resource.legacyIdentifier == resource.legacyIdentifier && $0.resource.location == resource.location
            }) ?? open(resource, startReading: false)
            activate(reader); reader.loadSearchResult(result, focus: focus); activeTool = nil
        } catch {
            if activeTool == .referenceSearch { referenceSearch.showOpeningError(error.localizedDescription) }
            else if activeTool == .passageGuide { passageGuide.showOpeningError(error.localizedDescription) }
            else { search.error = error.localizedDescription }
        }
    }
}

@MainActor extension ReaderSession {
    func loadSearchResult(_ result: LibrarySearchResult, focus: WorkspaceSearchResultFocus = .automatic) {
        guard focus.isValid(for: result) else { error = LibronixBookError.sourceChanged.localizedDescription; return }
        let selection: NSRange?
        switch focus {
        case .automatic: selection = result.hits.first?.range.nsRange ?? (result.externalHits.isEmpty ? result.verseRange?.nsRange : nil)
        case .reader(let range): selection = range.nsRange
        case .external: selection = nil
        case .summary: selection = result.hitCount == 0 ? result.verseRange?.nsRange : nil
        }
        load(.init(ordinal: result.sectionOrdinal), selection: selection,
             expectedFingerprint: result.decodedTextSHA256, expectedSourceStamps: result.sourceStamps)
    }
}
