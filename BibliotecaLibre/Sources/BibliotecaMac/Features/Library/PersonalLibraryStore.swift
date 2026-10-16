import AppKit
import Foundation
import LibronixCore
import Observation

@MainActor @Observable final class PersonalLibraryStore {
    private(set) var favorites = FavoritesDocument()
    private(set) var bookmarks = NumberedBookmarks()
    var errorMessage: String?
    @ObservationIgnored private let favoritesFile: PersonalStateFile<FavoritesDocument>
    @ObservationIgnored private let bookmarksFile: PersonalStateFile<NumberedBookmarks>
    private var undoStates: [FavoritesDocument] = []
    private var redoStates: [FavoritesDocument] = []
    @ObservationIgnored private var favoritesWritable = false
    @ObservationIgnored private var bookmarksWritable = false
    var canUndo: Bool { !undoStates.isEmpty }
    var canRedo: Bool { !redoStates.isEmpty }
    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Libron-X/Personal", isDirectory: true)
        favoritesFile = PersonalStateFile(url: root.appendingPathComponent("favorites.json"))
        bookmarksFile = PersonalStateFile(url: root.appendingPathComponent("bookmarks.json"))
        do {
            if let value = try favoritesFile.load() { try value.validate(); favorites = value }
            favoritesWritable = true
        } catch { errorMessage = error.localizedDescription }
        do {
            if let value = try bookmarksFile.load() { try value.validate(); bookmarks = value }
            bookmarksWritable = true
        } catch { errorMessage = error.localizedDescription }
    }
    func change(_ action: (inout FavoritesDocument) throws -> Void) {
        guard favoritesWritable else { errorMessage = "El archivo de favoritos necesita una versión compatible antes de editarse."; return }
        do {
            var next = favorites; try action(&next); try next.validate()
            guard next != favorites else { return }
            try favoritesFile.save(next)
            undoStates.append(favorites); if undoStates.count > 100 { undoStates.removeFirst() }
            redoStates = []; favorites = next
        } catch { errorMessage = error.localizedDescription }
    }
    func undo() {
        guard let next = undoStates.last else { return }
        do { try favoritesFile.save(next); redoStates.append(favorites); favorites = next; undoStates.removeLast() }
        catch { errorMessage = error.localizedDescription }
    }
    func redo() {
        guard let next = redoStates.last else { return }
        do { try favoritesFile.save(next); undoStates.append(favorites); favorites = next; redoStates.removeLast() }
        catch { errorMessage = error.localizedDescription }
    }
    func setBookmark(_ slot: Int, location: ReaderLocation?) {
        guard bookmarksWritable else { errorMessage = "El archivo de marcadores necesita una versión compatible antes de editarse."; return }
        do { var next = bookmarks; try next.set(slot, location: location); try bookmarksFile.save(next); bookmarks = next }
        catch { errorMessage = error.localizedDescription }
    }
    func clearBookmarks() {
        guard bookmarksWritable else { errorMessage = "El archivo de marcadores necesita una versión compatible antes de editarse."; return }
        do { var next = bookmarks; next.clear(); try bookmarksFile.save(next); bookmarks = next }
        catch { errorMessage = error.localizedDescription }
    }
    func importFavorites() {
        let panel = NSOpenPanel(); panel.title = "Importar favoritos de Libronix"; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
                let imported = try FavoritesDocument.importingLegacyXML(Data(contentsOf: url))
                self.change { current in for item in imported.items { current.items.append(item) } }
            } catch { self.errorMessage = error.localizedDescription }
        }
    }
}
