import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct OriginalFavoriteNavigationTests {
    @Test func importedFavoriteOpensCheckedOriginalPosition() async throws {
        let fixture = try OriginalFavoriteFixture(); defer { fixture.remove() }
        let personal = WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: personal); workspace.resources = fixture.resources
        let xml = Data(#"<favorites-collection><title>Own</title><favorite command="jump|pos=LLS-AOL:0.12.0|ref=bible.64.1.1|res=LLS:1.0.3"><title>Own favorite</title></favorite></favorites-collection>"#.utf8)
        let favorite = try #require(FavoritesDocument.importingLegacyXML(xml).items.first)
        workspace.openFavorite(favorite)
        for _ in 0..<500 where workspace.originalFavoriteTask != nil || workspace.activeReader?.isLoading == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reader = try #require(workspace.activeReader)
        #expect(workspace.error == nil && reader.error == nil)
        #expect(reader.page?.text == "Edition A · John1")
        #expect(reader.selectedRange == NSRange(location: 12, length: 0))
        #expect(favorite.kind == .legacyCommand && favorite.legacyCommand != nil)
    }

    @Test func missingAmbiguousAndInvalidCommandsDoNotOpenAReader() throws {
        let fixture = try OriginalFavoriteFixture(); defer { fixture.remove() }
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")))
        let command = "jump|pos=LLS-AOL:0.12.0|res=LLS:1.0.3"
        let favorite = LibraryFavorite(title: "Own", kind: .legacyCommand, legacyCommand: command)
        workspace.openFavorite(favorite)
        #expect(workspace.error != nil && workspace.readers.isEmpty)
        let original = fixture.resources[0]
        let duplicate = LibraryResource(location: fixture.root.appendingPathComponent("duplicate.LSF"), title: "Duplicate", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName, legacyIdentifier: original.legacyIdentifier)
        workspace.resources = [original, duplicate]; workspace.error = nil
        workspace.openFavorite(favorite)
        #expect(workspace.error != nil && workspace.readers.isEmpty)
        workspace.resources = [original]; workspace.error = nil
        workspace.openFavorite(.init(title: "Invalid", kind: .legacyCommand, legacyCommand: "run|res=LLS:1.0.3"))
        #expect(workspace.error != nil && workspace.readers.isEmpty)
    }

    @Test func newerNavigationCancelsAnOriginalFavorite() async throws {
        let fixture = try OriginalFavoriteFixture(); defer { fixture.remove() }
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")))
        workspace.resources = fixture.resources
        workspace.openFavorite(.init(title: "Own", kind: .legacyCommand, legacyCommand: "jump|pos=LLS-AOL:0.12.0|res=LLS:1.0.3"))
        let newer = workspace.open(fixture.resources[1])
        for _ in 0..<500 where newer.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(workspace.originalFavoriteTask == nil && workspace.activeReader === newer)
        #expect(workspace.readers.count == 1 && newer.resource.id == fixture.resources[1].id)
    }

    @Test func corruptIndexDoesNotNavigate() async throws {
        let fixture = try OriginalFavoriteFixture(); defer { fixture.remove() }
        let index = try #require(fixture.resources[0].indexLocation)
        try Data("broken index".utf8).write(to: index)
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")))
        workspace.resources = fixture.resources
        workspace.openFavorite(.init(title: "Own", kind: .legacyCommand, legacyCommand: "jump|pos=LLS-AOL:0.12.0|res=LLS:1.0.3"))
        for _ in 0..<500 where workspace.originalFavoriteTask != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(workspace.originalFavoriteTask == nil && workspace.error != nil && workspace.readers.isEmpty)
    }
}
