import Foundation
import Testing
@testable import LibronixCore

@Suite struct PersonalLibraryStateTests {
    private func location() -> ReaderLocation {
        ReaderLocation(resourceID: "/own/edition.LSF", legacyIdentifier: "synthetic-edition", format: .legacyLSF,
            sectionOrdinal: 92, reference: "John 1:5", textFingerprint: "own-source-fingerprint")
    }
    @Test func hierarchyMovesAreAtomicAndCyclesOrLeafParentsAreRejected() throws {
        let folder = LibraryFavorite(title: "Study", kind: .folder)
        let nested = LibraryFavorite(parentID: folder.id, title: "Nested", kind: .folder)
        let favorite = LibraryFavorite(parentID: nested.id, title: "🦉 Génesis", kind: .location, location: location())
        var doc = FavoritesDocument()
        for item in [folder, nested, favorite] { try doc.insert(item) }
        let before = doc
        #expect(throws: PersonalStateError.self) { try doc.move(folder.id, into: nested.id) }
        #expect(doc == before)
        #expect(throws: PersonalStateError.self) { try doc.move(nested.id, into: favorite.id) }
        #expect(doc == before)
        try doc.move(favorite.id, into: nil); try doc.rename(favorite.id, title: "שלום — λόγος")
        #expect(doc.children(of: nil).count == 2)
        #expect(doc.items.last?.title == "שלום — λόγος")
        doc.remove(folder.id); #expect(doc.items.map(\.id) == [favorite.id])
    }
    @Test func siblingReorderingPreservesDescendantsDestinationsAndOtherFolders() throws {
        let a = LibraryFavorite(title: "A", kind: .folder), b = LibraryFavorite(title: "B", kind: .folder)
        let child = LibraryFavorite(parentID: a.id, title: "Child", kind: .location, location: location())
        let other = LibraryFavorite(parentID: b.id, title: "Other", kind: .location, location: location())
        var doc = FavoritesDocument(); for item in [a, child, b, other] { try doc.insert(item) }
        try doc.reorder(b.id, by: -1)
        #expect(doc.children(of: nil).map(\.id) == [b.id, a.id])
        #expect(doc.children(of: a.id) == [child] && doc.children(of: b.id) == [other])
        let before = doc
        try doc.reorder(b.id, by: -1); #expect(doc == before)
        #expect(throws: PersonalStateError.self) { try doc.reorder(child.id, by: 2) }
        #expect(doc == before)
        #expect(try JSONDecoder().decode(FavoritesDocument.self, from: JSONEncoder().encode(doc)) == doc)
    }
    @Test func importedFavoritesKeepNestedTitlesAndOpaqueOriginalCoordinates() throws {
        let source = Data("""
        <favorites-collection><title>Favorites</title><favorites-collection><title>Study</title>
        <favorites-collection><title>Nested</title><favorite command="jump|pos=LLS-AOL:92&lt;BIBLE.64.1&gt;.305.0|ref=bible+rvr60.64.1.5|res=LLS:OWN">
        <title>Own synthetic favorite</title></favorite></favorites-collection></favorites-collection></favorites-collection>
        """.utf8)
        let doc = try FavoritesDocument.importingLegacyXML(source)
        #expect(doc.items.map(\.title) == ["Study", "Nested", "Own synthetic favorite"])
        #expect(doc.items[1].parentID == doc.items[0].id && doc.items[2].parentID == doc.items[1].id)
        #expect(doc.items[2].location == nil)
        #expect(doc.items[2].legacyCommand == "jump|pos=LLS-AOL:92<BIBLE.64.1>.305.0|ref=bible+rvr60.64.1.5|res=LLS:OWN")
        #expect(try JSONDecoder().decode(FavoritesDocument.self, from: JSONEncoder().encode(doc)) == doc)
    }
    @Test func conflictingWritersKeepTheConfirmedDocumentAndItsPreviousVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("favorites.json")
        let first = PersonalStateFile<FavoritesDocument>(url: url), second = PersonalStateFile<FavoritesDocument>(url: url)
        #expect(try first.load() == nil); #expect(try second.load() == nil)
        var one = FavoritesDocument(); try one.insert(LibraryFavorite(title: "First", kind: .folder))
        try first.save(one)
        #expect(throws: PersonalStateError.self) { try second.save(FavoritesDocument()) }
        #expect(try second.load() == one)
        var two = one; try two.rename(one.items[0].id, title: "Latest")
        try second.save(two)
        #expect(try JSONDecoder().decode(FavoritesDocument.self, from: Data(contentsOf: url.appendingPathExtension("previous"))) == one)
        #expect(throws: PersonalStateError.self) { try first.save(one) }
        #expect(try first.load() == two)
    }
    @Test func bookmarksPreserveOnlyNineTypedDestinationsAndClearIndependently() throws {
        var bookmarks = NumberedBookmarks(); try bookmarks.set(9, location: location())
        #expect(throws: PersonalStateError.self) { try bookmarks.set(0, location: location()) }
        #expect(throws: PersonalStateError.self) { try bookmarks.set(10, location: location()) }
        #expect(try JSONDecoder().decode(NumberedBookmarks.self, from: JSONEncoder().encode(bookmarks)) == bookmarks)
        try bookmarks.set(9, location: nil); #expect(bookmarks.slots.isEmpty)
        try bookmarks.set(1, location: location()); bookmarks.clear(); #expect(bookmarks.slots.isEmpty)
    }
    @Test func workspaceRoundTripKeepsIndependentFiltersQueriesHistoryAndMembership() throws {
        var window = WorkspaceWindowState(); window.location = location(); window.selectedResourceID = window.location?.resourceID
        window.section = "search"; window.linkGroup = .a; window.readerTab = "preview"
        window.catalogQuery = "λόγος"; window.catalogSort = "author"; window.catalogFormat = .legacyLSF
        window.history.visit(0); window.history.visit(92)
        window.search.query = "\"own words\" AND test"; window.search.unit = "bibleVerse"
        window.frame = [40, 40, 1280, 800]
        let doc = WorkspaceDocument(name: "Own workspace", windows: [window]); try doc.validate()
        let result = try JSONDecoder().decode(WorkspaceDocument.self, from: JSONEncoder().encode(doc))
        try result.validate(); #expect(result == doc)
        var invalid = doc; invalid.schemaVersion = 2
        #expect(throws: PersonalStateError.self) { try invalid.validate() }
        invalid = doc; invalid.windows.append(window)
        #expect(throws: PersonalStateError.self) { try invalid.validate() }
        invalid = doc; invalid.windows[0].history.visit(99)
        #expect(throws: PersonalStateError.self) { try invalid.validate() }
    }
    @Test func malformedPersistedHistoryCannotCreateAnOutOfBoundsCursor() throws {
        for source in [#"{"limit":10,"sections":[1],"cursor":20}"#, #"{"limit":10,"sections":[-1],"cursor":0}"#,
                       #"{"limit":0,"sections":[],"cursor":-1}"#] {
            #expect(throws: PersonalStateError.self) { try JSONDecoder().decode(ReadingHistory.self, from: Data(source.utf8)) }
        }
    }
}
