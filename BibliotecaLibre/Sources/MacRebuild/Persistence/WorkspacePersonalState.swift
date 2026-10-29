import Foundation
import LibronixCore
import Observation

struct WorkspacePersonalSnapshot: Codable {
    var schemaVersion = 1
    var favorites = FavoritesDocument()
    var highlights: [ReaderHighlight] = []
    var documents: [StudyDocument] = []
    func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        try favorites.validate()
        guard documents.count <= 100, highlights.count <= 100_000,
              Set(documents.map(\.id)).count == documents.count,
              highlights.allSatisfy({ $0.ordinal >= 0 && $0.range.location >= 0 && $0.range.length > 0 &&
                  $0.range.length < 10_000_000 && $0.range.location <= Int.max - $0.range.length &&
                  ["yellow", "green", "blue", "pink"].contains($0.color) }) else { throw PersonalStateError.invalid("Los datos personales contienen entradas incompatibles.") }
        for document in documents { try document.validate() }
    }
}

@MainActor @Observable final class WorkspacePersonalState {
    var favorites = FavoritesDocument()
    private(set) var bookmarks = NumberedBookmarks()
    private(set) var bookmarkLoadError: String?
    private(set) var readingPlans = ReadingPlans()
    private(set) var readingPlansLoadError: String?
    private(set) var prayerJournal = PrayerJournal()
    private(set) var prayerJournalLoadError: String?
    private(set) var scriptureMemory = ScriptureMemory()
    private(set) var scriptureMemoryLoadError: String?
    private(set) var studyAssessments = StudyAssessments()
    private(set) var studyAssessmentsLoadError: String?
    private(set) var searchWordLists = SearchWordLists()
    private(set) var searchWordListsLoadError: String?
    private(set) var namedBibleRanges = NamedBibleSearchRanges()
    private(set) var namedBibleRangesLoadError: String?
    private(set) var researchInbox = ResearchInbox()
    private(set) var researchInboxLoadError: String?
    private(set) var bibleCopyState = BibleCopyPersonalState()
    private(set) var bibleCopyLoadError: String?
    let searchHistory: WorkspaceSearchHistory
    let savedQueries: WorkspaceSavedQueries
    var highlights: [ReaderHighlight] = []
    var documents: [StudyDocument] = []
    var selectedDocumentID: UUID?
    var loadError: String?
    @ObservationIgnored private let file: PersonalStateFile<WorkspacePersonalSnapshot>
    @ObservationIgnored private let bookmarkFile: PersonalStateFile<NumberedBookmarks>
    @ObservationIgnored private let readingPlansFile: PersonalStateFile<ReadingPlans>
    @ObservationIgnored private let prayerJournalFile: PersonalStateFile<PrayerJournal>
    @ObservationIgnored private let scriptureMemoryFile: PersonalStateFile<ScriptureMemory>
    @ObservationIgnored private let studyAssessmentsFile: PersonalStateFile<StudyAssessments>
    @ObservationIgnored private let searchWordListsFile: PersonalStateFile<SearchWordLists>
    @ObservationIgnored private let namedBibleRangesFile: PersonalStateFile<NamedBibleSearchRanges>
    @ObservationIgnored private let researchInboxFile: PersonalStateFile<ResearchInbox>
    @ObservationIgnored private let bibleCopyFile: PersonalStateFile<BibleCopyPersonalState>
    @ObservationIgnored private var bookmarksWritable = false
    @ObservationIgnored private var readingPlansWritable = false
    @ObservationIgnored private var prayerJournalWritable = false
    @ObservationIgnored private var scriptureMemoryWritable = false
    @ObservationIgnored private var studyAssessmentsWritable = false
    @ObservationIgnored private var searchWordListsWritable = false
    @ObservationIgnored private var namedBibleRangesWritable = false
    @ObservationIgnored private var researchInboxWritable = false
    @ObservationIgnored private var bibleCopyWritable = false
    @ObservationIgnored private var canSave = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    init(url: URL? = nil) {
        let path = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.libronx.mac.rebuild/personal.json")
        searchHistory = WorkspaceSearchHistory(url: path.deletingLastPathComponent().appendingPathComponent("search-history.json"))
        savedQueries = WorkspaceSavedQueries(url: path.deletingLastPathComponent().appendingPathComponent("saved-queries.json"))
        file = PersonalStateFile(url: path)
        bookmarkFile = PersonalStateFile(url: path.deletingLastPathComponent().appendingPathComponent("numbered-bookmarks.json"))
        readingPlansFile = PersonalStateFile(url: path.deletingLastPathComponent().appendingPathComponent("reading-plans.json"))
        prayerJournalFile = PersonalStateFile(url: path.deletingLastPathComponent().appendingPathComponent("prayer-journal.json"))
        scriptureMemoryFile = PersonalStateFile(url: path.deletingLastPathComponent().appendingPathComponent("scripture-memory.json"))
        studyAssessmentsFile = PersonalStateFile(url: path.deletingLastPathComponent().appendingPathComponent("study-assessments.json"))
        searchWordListsFile = PersonalStateFile(url: path.deletingLastPathComponent().appendingPathComponent("search-word-lists.json"))
        namedBibleRangesFile = PersonalStateFile(url: path.deletingLastPathComponent().appendingPathComponent("named-bible-ranges.json"))
        researchInboxFile = PersonalStateFile(url: path.deletingLastPathComponent().appendingPathComponent("research-inbox.json"))
        bibleCopyFile = PersonalStateFile(url: path.deletingLastPathComponent().appendingPathComponent("bible-copy-styles.json"))
        do {
            if let saved = try file.load() {
                try saved.validate(); favorites = saved.favorites; highlights = saved.highlights; documents = saved.documents
            }
            canSave = true; selectedDocumentID = documents.first?.id
        } catch { loadError = error.localizedDescription }
        do {
            if let saved = try bookmarkFile.load() { try saved.validate(); bookmarks = saved }
            bookmarksWritable = true
        } catch { bookmarkLoadError = error.localizedDescription }
        do {
            if let saved = try readingPlansFile.load() { try saved.validate(); readingPlans = saved }
            readingPlansWritable = true
        } catch { readingPlansLoadError = error.localizedDescription }
        do {
            if let saved = try prayerJournalFile.load() { try saved.validate(); prayerJournal = saved }
            prayerJournalWritable = true
        } catch { prayerJournalLoadError = error.localizedDescription }
        do {
            if let saved = try scriptureMemoryFile.load() { try saved.validate(); scriptureMemory = saved }
            scriptureMemoryWritable = true
        } catch { scriptureMemoryLoadError = error.localizedDescription }
        do {
            if let saved = try studyAssessmentsFile.load() { try saved.validate(); studyAssessments = saved }
            studyAssessmentsWritable = true
        } catch { studyAssessmentsLoadError = error.localizedDescription }
        do {
            if let saved = try searchWordListsFile.load() { try saved.validate(); searchWordLists = saved }
            searchWordListsWritable = true
        } catch { searchWordListsLoadError = error.localizedDescription }
        do {
            if let saved = try namedBibleRangesFile.load() { try saved.validate(); namedBibleRanges = saved }
            namedBibleRangesWritable = true
        } catch { namedBibleRangesLoadError = error.localizedDescription }
        do {
            if let saved = try researchInboxFile.load() { try saved.validate(); researchInbox = saved }
            researchInboxWritable = true
        } catch { researchInboxLoadError = error.localizedDescription }
        do {
            if let saved = try bibleCopyFile.load() { try saved.validate(); bibleCopyState = saved }
            bibleCopyWritable = true
        } catch { bibleCopyLoadError = error.localizedDescription }
    }
    func editBibleCopyState(_ edit: (inout BibleCopyPersonalState) throws -> Void) throws {
        guard bibleCopyWritable else { throw PersonalStateError.invalid(bibleCopyLoadError ?? "No se pudieron abrir las plantillas de copia.") }
        var next = bibleCopyState
        try edit(&next); try next.validate()
        guard next != bibleCopyState else { return }
        try bibleCopyFile.save(next); bibleCopyState = next
    }
    func editResearchInbox(_ edit: (inout ResearchInbox) throws -> Void) throws {
        guard researchInboxWritable else { throw PersonalStateError.invalid(researchInboxLoadError ?? "No se pudo abrir la bandeja de investigación.") }
        var next = researchInbox
        try edit(&next); try next.validate()
        guard next != researchInbox else { return }
        try researchInboxFile.save(next); researchInbox = next
    }
    func editNamedBibleRanges(_ edit: (inout NamedBibleSearchRanges) throws -> Void) throws {
        guard namedBibleRangesWritable else { throw PersonalStateError.invalid(namedBibleRangesLoadError ?? "No se pudieron abrir los rangos guardados.") }
        var next = namedBibleRanges
        try edit(&next); try next.validate()
        guard next != namedBibleRanges else { return }
        try namedBibleRangesFile.save(next); namedBibleRanges = next
    }
    func editSearchWordLists(_ edit: (inout SearchWordLists) throws -> Void) throws {
        guard searchWordListsWritable else { throw PersonalStateError.invalid(searchWordListsLoadError ?? "No se pudieron abrir las listas de palabras.") }
        var next = searchWordLists
        try edit(&next); try next.validate()
        guard next != searchWordLists else { return }
        try searchWordListsFile.save(next); searchWordLists = next
    }
    func editStudyAssessments(_ edit: (inout StudyAssessments) throws -> Void) throws {
        guard studyAssessmentsWritable else { throw PersonalStateError.invalid(studyAssessmentsLoadError ?? "No se pudieron abrir las autoevaluaciones.") }
        var next = studyAssessments
        try edit(&next); try next.validate()
        guard next != studyAssessments else { return }
        try studyAssessmentsFile.save(next); studyAssessments = next
    }
    func editScriptureMemory(_ edit: (inout ScriptureMemory) throws -> Void) throws {
        guard scriptureMemoryWritable else { throw PersonalStateError.invalid(scriptureMemoryLoadError ?? "No se pudieron abrir los ejercicios de memorización.") }
        var next = scriptureMemory
        try edit(&next); try next.validate()
        guard next != scriptureMemory else { return }
        try scriptureMemoryFile.save(next); scriptureMemory = next
    }
    func saveScriptureMemoryCard(original: ScriptureMemoryCard?, replacement: ScriptureMemoryCard) throws {
        try editScriptureMemory { state in
            if let original {
                guard original.id == replacement.id,
                      let index = state.cards.firstIndex(where: { $0.id == original.id }), state.cards[index] == original
                else { throw PersonalStateError.concurrentChange }
                state.cards[index] = replacement
            } else { state.cards.append(replacement) }
        }
    }
    func editPrayerJournal(_ edit: (inout PrayerJournal) throws -> Void) throws {
        guard prayerJournalWritable else { throw PersonalStateError.invalid(prayerJournalLoadError ?? "No se pudo abrir la lista de oración.") }
        var next = prayerJournal
        try edit(&next); try next.validate()
        guard next != prayerJournal else { return }
        try prayerJournalFile.save(next)
        prayerJournal = next
    }
    func savePrayerRequest(original: PrayerRequest?, replacement: PrayerRequest) throws {
        try editPrayerJournal { state in
            if let original {
                guard replacement.id == original.id, let index = state.requests.firstIndex(where: { $0.id == original.id }),
                      state.requests[index] == original else { throw PersonalStateError.concurrentChange }
                state.requests[index] = replacement
            } else { state.requests.append(replacement) }
        }
    }
    func editReadingPlans(_ edit: (inout ReadingPlans) throws -> Void) throws {
        guard readingPlansWritable else { throw PersonalStateError.invalid(readingPlansLoadError ?? "No se pudieron abrir los planes de lectura.") }
        var next = readingPlans
        try edit(&next); try next.validate()
        guard next != readingPlans else { return }
        try readingPlansFile.save(next)
        readingPlans = next
    }
    func saveScheduledReading(planID: UUID, original: ScheduledReading?, replacement: ScheduledReading) throws {
        try editReadingPlans { state in
            guard let index = state.plans.firstIndex(where: { $0.id == planID }) else { throw PersonalStateError.concurrentChange }
            if let original {
                guard replacement.id == original.id,
                      let item = state.plans[index].readings.firstIndex(where: { $0.id == original.id }),
                      state.plans[index].readings[item] == original else { throw PersonalStateError.concurrentChange }
                var updated = replacement
                if original.reference != replacement.reference { updated.completed = false }
                else { updated.completed = original.completed }
                state.plans[index].readings[item] = updated
            } else {
                state.plans[index].readings.append(replacement)
            }
        }
    }
    func setBookmark(_ slot: Int, location: ReaderLocation?) throws {
        guard bookmarksWritable else { throw PersonalStateError.invalid(bookmarkLoadError ?? "No se pudo abrir el archivo de marcadores.") }
        var updated = bookmarks
        try updated.set(slot, location: location)
        try updated.validate()
        guard updated != bookmarks else { return }
        try bookmarkFile.save(updated)
        bookmarks = updated
    }
    func appendExtractedReferences(_ references: [String], to documentID: UUID) throws {
        guard !references.isEmpty else { return }
        guard let index = documents.firstIndex(where: { $0.id == documentID && $0.kind == .verseList }) else {
            throw PersonalStateError.invalid("La lista de versículos ya no está disponible.")
        }
        guard references.count <= 100_000 - documents[index].verses.count else { throw PersonalStateError.tooLarge }
        for reference in references { _ = try BibleReferenceQuery.parse(reference) }
        var updated = documents
        updated[index].verses.append(contentsOf: references.map { StudyVerseEntry(reference: $0) })
        try updated[index].validate()
        try replaceDocuments(updated)
    }
    func save() throws {
        saveTask?.cancel()
        guard canSave else { throw PersonalStateError.invalid(loadError ?? "No se pudo abrir el archivo personal; se conservaron sus datos.") }
        let snapshot = WorkspacePersonalSnapshot(favorites: favorites, highlights: highlights, documents: documents)
        try snapshot.validate(); try file.save(snapshot); loadError = nil
    }
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)); try self?.save() }
            catch is CancellationError {} catch { self?.loadError = error.localizedDescription }
        }
    }
    /// Apply a favorite edit only after the complete personal snapshot is
    /// accepted and written. A conflict restores the in-memory hierarchy.
    func editFavorites(_ edit: (inout FavoritesDocument) throws -> Void) throws {
        var updated = favorites
        try edit(&updated); try updated.validate()
        guard updated != favorites else { return }
        let previous = favorites
        favorites = updated
        do { try save() }
        catch { favorites = previous; throw error }
    }
    /// Preserve the existing hierarchy unless the entire import and save succeed.
    func importOriginalFavorites(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let bytes = try input.read(upToCount: MetadataXMLReader.maximumFileBytes + 1) ?? Data()
        guard bytes.count <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
        let imported = try FavoritesDocument.importingLegacyXML(bytes)
        try editFavorites { $0.items.append(contentsOf: imported.items) }
    }
    func renameNote(_ id: UUID, in documentID: UUID, title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let document = documents.firstIndex(where: { $0.id == documentID }),
              let note = documents[document].notes.firstIndex(where: { $0.id == id }) else { return }
        let previous = documents[document].notes[note]
        documents[document].notes[note].title = title
        documents[document].notes[note].modifiedUTC = ISO8601DateFormatter().string(from: Date())
        do { try save() }
        catch { documents[document].notes[note] = previous; throw error }
    }
    /// Source markup and provenance remain untouched; only the owned native
    /// editing representation changes. The normal debounced save keeps typing
    /// responsive and preserves unsaved edits in memory if a disk write fails.
    func updateNoteRichText(_ id: UUID, in documentID: UUID, data: Data) throws {
        guard let document = documents.firstIndex(where: { $0.id == documentID }),
              let note = documents[document].notes.firstIndex(where: { $0.id == id }) else { return }
        _ = try NoteRichTextCodec.decode(data)
        guard documents[document].notes[note].editedRTF != data else { return }
        documents[document].schemaVersion = 2
        documents[document].notes[note].editedRTF = data
        documents[document].notes[note].modifiedUTC = ISO8601DateFormatter().string(from: Date())
        scheduleSave()
    }
    /// The caller must obtain confirmation before invoking this mutation.
    func deleteNotes(_ ids: Set<UUID>, in documentID: UUID) throws {
        guard !ids.isEmpty, let document = documents.firstIndex(where: { $0.id == documentID }) else { return }
        guard documents[document].notes.contains(where: { ids.contains($0.id) }) else { return }
        var updated = documents
        updated[document] = try StudyNoteOrganization.deleting(ids, from: documents[document])
        try replaceDocuments(updated)
    }
    func moveNotes(_ ids: Set<UUID>, from sourceID: UUID, to destinationID: UUID,
                   parentID: UUID? = nil, beforeID: UUID? = nil) throws {
        let updated = try StudyNoteOrganization.moving(ids, from: sourceID, to: destinationID,
            parentID: parentID, beforeID: beforeID, documents: documents)
        try replaceDocuments(updated)
        selectedDocumentID = destinationID
    }
    @discardableResult func duplicateNotes(_ ids: Set<UUID>, in documentID: UUID) throws -> Set<UUID> {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return [] }
        let previousIDs = Set(documents[index].notes.map(\.id))
        var updated = documents
        updated[index] = try StudyNoteOrganization.duplicating(ids, in: documents[index], titleSuffix: L("Copia"))
        try replaceDocuments(updated)
        return Set(updated[index].notes.map(\.id)).subtracting(previousIDs)
    }
    func sortNotes(in documentID: UUID, by order: StudyNoteSort) throws {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
        var updated = documents
        updated[index] = try StudyNoteOrganization.sorting(documents[index], by: order)
        try replaceDocuments(updated)
    }
    func setNoteProperties(_ id: UUID, in documentID: UUID, values: [String: String]) throws {
        guard let document = documents.firstIndex(where: { $0.id == documentID }),
              let note = documents[document].notes.firstIndex(where: { $0.id == id }) else { return }
        var updated = documents
        updated[document].schemaVersion = 2
        updated[document].notes[note].properties = values
        updated[document].notes[note].modifiedUTC = ISO8601DateFormatter().string(from: Date())
        try replaceDocuments(updated)
    }
    func moveNote(_ id: UUID, in documentID: UUID, by delta: Int) throws {
        guard [-1, 1].contains(delta), let document = documents.first(where: { $0.id == documentID }),
              let note = document.notes.first(where: { $0.id == id }) else { return }
        let siblings = document.notes.filter { $0.parentID == note.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == id }), siblings.indices.contains(index + delta) else { return }
        let before = delta < 0 ? siblings[index - 1].id : siblings.indices.contains(index + 2) ? siblings[index + 2].id : nil
        try moveNotes([id], from: documentID, to: documentID, parentID: note.parentID, beforeID: before)
    }
    private func replaceDocuments(_ updated: [StudyDocument]) throws {
        let previous = documents
        documents = updated
        do { try save() }
        catch { documents = previous; throw error }
    }
    func previousDocuments() throws -> [StudyDocument] {
        try PreviousDocumentRecovery.read(from: file.url)
    }
    func recoverPreviousDocument(_ original: StudyDocument, title: String) throws {
        // Re-read just before writing; do not restore a stale or replaced backup.
        guard try previousDocuments().contains(original) else { throw PersonalStateError.concurrentChange }
        let copy = try PreviousDocumentRecovery.copy(original, title: title)
        try PreviousDocumentRecovery.archive(original, from: file.url)
        try replaceDocuments(documents + [copy])
        selectedDocumentID = copy.id
    }
    @discardableResult func create(_ kind: StudyDocumentKind) -> UUID {
        let document = StudyDocument(title: kind == .notebook ? "Mis notas" : "Lista de versículos", kind: kind)
        documents.append(document); selectedDocumentID = document.id; scheduleSave(); return document.id
    }
}
