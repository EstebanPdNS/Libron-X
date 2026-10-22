import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct LibraryResourceSortTests {
    @Test func titlesUseNaturalOrderAndReverseWithoutChangingResourceIdentity() {
        let ten = resource("Volume 10", author: "Alpha"), two = resource("Volume 2", author: "Zulu")
        let rows = [ten, two]
        #expect(rows.sortedForLibrary(using: [LibraryResourceSort(.title)]).map(\.id) == [two.id, ten.id])
        #expect(rows.sortedForLibrary(using: [LibraryResourceSort(.title, order: .reverse)]).map(\.id) == [ten.id, two.id])
        #expect(rows.sortedForLibrary(using: [LibraryResourceSort(.author)]).map(\.id) == [ten.id, two.id])
        #expect(rows.sortedForLibrary(using: [LibraryResourceSort(.author, order: .reverse)]).map(\.id) == [two.id, ten.id])
    }
    @Test func displayedLanguageNamesGroupAliasesAndTitlesBreakTiesDeterministically() {
        let b = resource("B", language: "spa"), a = resource("A", language: "es"), c = resource("C", language: "en")
        let sort = LibraryResourceSort(.language)
        #expect(sort.compare(a, b) == .orderedSame)
        let sorted = [b, c, a].sortedForLibrary(using: [sort])
        #expect(sorted.firstIndex(of: b) == sorted.firstIndex(of: a).map { $0 + 1 })
        #expect(Set(sorted.map(\.id)) == Set([a.id, b.id, c.id]))
        #expect([a, b, c].sortedForLibrary(using: [sort]) == sorted)
    }
    @Test func libraryFilteringAndSelectionSurviveChangingFieldAndDirection() {
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("libronx-sort-\(UUID()).json")))
        let alpha = resource("Alpha", author: "Zulu"), beta = resource("Beta", author: "Alpha")
        workspace.resources = [beta, alpha, resource("Excluded", language: "en")]
        workspace.libraryGroup = "language:es"; workspace.librarySelection = alpha.id
        workspace.librarySortField = .author
        #expect(workspace.filteredResources.map(\.id) == [beta.id, alpha.id])
        workspace.librarySortOrder = .reverse
        #expect(workspace.filteredResources.map(\.id) == [alpha.id, beta.id])
        workspace.librarySortField = .title
        #expect(workspace.filteredResources.map(\.id) == [beta.id, alpha.id])
        #expect(workspace.librarySelection == alpha.id && workspace.libraryGroup == "language:es")
    }
    private func resource(_ title: String, author: String = "", language: String = "es") -> LibraryResource {
        var metadata = LibronMetadata(title: title, origin: "Authored test")
        metadata.authors = [author]; metadata.languages = [language]; metadata.resourceType = "Biblia"
        return .init(location: URL(fileURLWithPath: "/authored/" + title), title: title, author: author,
            languages: [language], byteCount: 0, format: .eSwordSQLite, support: .metadataOnly,
            provenance: .fileName, libron: metadata)
    }
}
