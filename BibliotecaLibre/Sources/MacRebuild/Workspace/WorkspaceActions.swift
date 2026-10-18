import AppKit
import LibronixCore

enum WorkspaceTool: String, Identifiable { case search, referenceSearch, documents, favorites, information, resources, topics, bibleCopy, windows, parallelSets, keyLinks, associations
    var id: String { rawValue }
}
struct ReaderHighlight: Identifiable, Codable, Equatable {
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
        copy.parallelSetID = reader.parallelSetID
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
        open(resource, destination: destination)
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
        search.run(availableResources, documents: personal.documents, scopeContext: searchScopeContext())
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
            try personal.favorites.insert(.init(title: reader.resource.title + " · " + (reader.currentReference ?? "Artículo \(page.destination.ordinal + 1)"),
                                               kind: .location, location: location))
            savePersonal()
        } catch { self.error = error.localizedDescription }
    }
    func openFavorite(_ favorite: LibraryFavorite) {
        guard let location = favorite.location, let resource = location.resolve(in: resources) else {
            error = L("El recurso de este favorito no está disponible en la biblioteca abierta."); return
        }
        open(resource, destination: .init(ordinal: location.sectionOrdinal, reference: location.reference))
        activeTool = nil
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
