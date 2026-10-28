import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct OriginalFavoriteImportTests {
    @Test func importsNestedCommandsWithoutReplacingExistingFavorites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        let existing = LibraryFavorite(title: "Existing", kind: .folder)
        try personal.editFavorites { try $0.insert(existing) }
        let url = root.appendingPathComponent("own.lbxfls")
        try Data(#"<favorites-collection><title>Own</title><favorites-collection><title>Folder</title><favorite command="jump|pos=LLS-AOL:0.12.0|res=LLS:1.0.3"><title>Position</title></favorite><favorite command="unsupported|opaque"><title>Other action</title></favorite></favorites-collection></favorites-collection>"#.utf8).write(to: url)
        try personal.importOriginalFavorites(from: url)
        let items = personal.favorites.items
        #expect(items.count == 4 && items[0] == existing)
        #expect(items[1].title == "Folder" && items[2].parentID == items[1].id && items[3].parentID == items[1].id)
        #expect(items[2].legacyCommand == "jump|pos=LLS-AOL:0.12.0|res=LLS:1.0.3" && items[3].legacyCommand == "unsupported|opaque")
        #expect(WorkspacePersonalState(url: root.appendingPathComponent("personal.json")).favorites == personal.favorites)
        try personal.importOriginalFavorites(from: url)
        #expect(personal.favorites.items.count == 7 && Set(personal.favorites.items.map(\.id)).count == 7)
    }

    @Test func invalidOrOversizeInputAndConcurrentChangesNeverOverwriteFavorites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("personal.json"), url = root.appendingPathComponent("input.xml")
        let writer = WorkspacePersonalState(url: stateURL), stale = WorkspacePersonalState(url: stateURL)
        let existing = LibraryFavorite(title: "Existing", kind: .folder)
        try writer.editFavorites { try $0.insert(existing) }
        try Data("<invalid/>".utf8).write(to: url)
        #expect(throws: (any Error).self) { try writer.importOriginalFavorites(from: url) }
        #expect(writer.favorites.items == [existing])
        try Data(repeating: 32, count: MetadataXMLReader.maximumFileBytes + 1).write(to: url)
        #expect(throws: PersonalStateError.self) { try writer.importOriginalFavorites(from: url) }
        #expect(writer.favorites.items == [existing])
        try Data(#"<favorites-collection><favorite command="opaque"><title>Own</title></favorite></favorites-collection>"#.utf8).write(to: url)
        #expect(throws: PersonalStateError.self) { try stale.importOriginalFavorites(from: url) }
        #expect(stale.favorites.items.isEmpty && WorkspacePersonalState(url: stateURL).favorites.items == [existing])
    }
}
