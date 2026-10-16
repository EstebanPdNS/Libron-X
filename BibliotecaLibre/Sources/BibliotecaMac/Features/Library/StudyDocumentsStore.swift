import AppKit
import Foundation
import CryptoKit
import LibronixCore
import Observation

@MainActor @Observable final class StudyDocumentsStore {
    private(set) var documents: [StudyDocument] = []
    private(set) var unsavedIDs: Set<UUID> = []
    var errorMessage: String?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var files: [UUID: PersonalStateFile<StudyDocument>] = [:]
    @ObservationIgnored private var pendingSaves: [UUID: Task<Void, Never>] = [:]
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Libron-X/Documents", isDirectory: true)
        do {
            guard FileManager.default.fileExists(atPath: self.directory.path) else { return }
            let urls = try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
                .filter { $0.pathExtension == "libronx-document" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard urls.count <= 10_000 else { throw PersonalStateError.tooLarge }
            for url in urls {
                do {
                    guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                    let file = PersonalStateFile<StudyDocument>(url: url)
                    guard let document = try file.load() else { continue }; try document.validate()
                    guard !documents.contains(where: { $0.id == document.id }) else { throw PersonalStateError.invalid("Dos documentos comparten el mismo identificador.") }
                    documents.append(document); files[document.id] = file
                } catch { errorMessage = "Un documento no pudo abrirse: \(error.localizedDescription)" }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func document(_ id: UUID?) -> StudyDocument? { documents.first { $0.id == id } }
    @discardableResult func create(kind: StudyDocumentKind, title: String) -> UUID? {
        do { return try insert(StudyDocument(title: title, kind: kind)) }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    @discardableResult func insert(_ document: StudyDocument) throws -> UUID {
        try document.validate()
        guard !documents.contains(where: { $0.id == document.id }) else { throw PersonalStateError.invalid("El documento ya está abierto.") }
        let file = PersonalStateFile<StudyDocument>(url: directory.appendingPathComponent(document.id.uuidString + ".libronx-document"))
        guard try file.load() == nil else { throw PersonalStateError.invalid("Ese documento ya existe en disco.") }
        try file.save(document); files[document.id] = file; documents.append(document); return document.id
    }
    func change(_ id: UUID, action: (inout StudyDocument) -> Void) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        var next = documents[index]; action(&next)
        do { try next.validate() } catch { errorMessage = error.localizedDescription; return }
        guard next != documents[index] else { return }
        documents[index] = next; unsavedIDs.insert(id); pendingSaves[id]?.cancel()
        pendingSaves[id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation(); self?.save(id) }
            catch { }
        }
    }
    func changeNote(_ documentID: UUID, noteID: UUID, action: (inout StudyNote) -> Void) {
        change(documentID) { document in
            guard let index = document.notes.firstIndex(where: { $0.id == noteID }) else { return }
            action(&document.notes[index]); document.notes[index].modifiedUTC = ISO8601DateFormatter().string(from: Date())
        }
    }
    func save(_ id: UUID) {
        pendingSaves[id]?.cancel(); pendingSaves[id] = nil
        guard unsavedIDs.contains(id), let document = document(id), let file = files[id] else { return }
        do { try file.save(document); unsavedIDs.remove(id) }
        catch { errorMessage = "Los cambios siguen abiertos, pero no se pudieron guardar: \(error.localizedDescription)" }
    }
    func flush() { for id in Array(unsavedIDs) { save(id) } }
    func importDocument(select: @escaping (UUID) -> Void) {
        let panel = NSOpenPanel(); panel.title = "Importar notas o listas de versículos"; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
                let data = try Data(contentsOf: url); guard data.count <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
                var document: StudyDocument
                if url.pathExtension == "libronx-document" { document = try JSONDecoder().decode(StudyDocument.self, from: data) }
                else { document = try StudyDocument.importingLegacyXML(data, sourceSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()) }
                document.id = UUID(); try document.validate(); select(try self.insert(document))
            } catch { self.errorMessage = error.localizedDescription }
        }
    }
    func exportDocument(_ id: UUID) {
        save(id)
        guard let document = document(id), !unsavedIDs.contains(id) else { return }
        let panel = NSSavePanel(); panel.title = "Guardar una copia de Libron-X"; panel.nameFieldStringValue = document.title + ".libronx-document"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let file = PersonalStateFile<StudyDocument>(url: url)
                if let previous = try file.load() { try previous.validate() }; try file.save(document)
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }
}
