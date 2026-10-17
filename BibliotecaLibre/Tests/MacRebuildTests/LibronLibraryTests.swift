import AppKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct LibronLibraryTests {
    func resource(_ title: String, language: String, author: String = "") -> LibraryResource {
        var metadata = LibronMetadata(title: title, origin: "e-Sword")
        metadata.languages = [language]; metadata.authors = [author]; metadata.resourceType = "Biblia"
        return .init(location: URL(fileURLWithPath: "/tmp/" + title), title: title, author: author, languages: [language], byteCount: 0, format: .eSwordSQLite, support: .metadataOnly, provenance: .fileName, libron: metadata)
    }
    @Test func languageGroupsSearchAndSortingComposeWithoutDiscardingOtherResources() {
        let workspace = StudyWorkspace()
        workspace.resources = [resource("Spanish Bible", language: "es"), resource("English Bible", language: "en"), resource("Portuguese Bible", language: "pt")]
        #expect(Set(workspace.libraryLanguages) == ["es","en","pt"])
        workspace.libraryQuery = "español"
        #expect(workspace.filteredResources.map(\.title) == ["Spanish Bible"])
        workspace.libraryQuery = ""; workspace.libraryGroup = "language:pt"
        #expect(workspace.filteredResources.map(\.title) == ["Portuguese Bible"])
        workspace.libraryQuery = "Bible"
        #expect(workspace.filteredResources.count == 1)
        workspace.libraryQuery = "English"
        #expect(workspace.filteredResources.isEmpty)
        #expect(workspace.resources.count == 3)
    }
    @Test func dictionarySelectionAcceptsOneUnicodeWordAndRejectsPhrases() {
        for value in ["amor","λόγος","אֱלֹהִים","محبت","H123","God’s"] { #expect(DictionaryController.singleWord(value) != nil) }
        for value in ["two words","una frase completa","","one\ntwo","word / phrase"] { #expect(DictionaryController.singleWord(value) == nil) }
        #expect(DictionaryController.singleWord(" «amor». ") == "amor")
        #expect(DictionaryLookupSource.key("ÉL") == DictionaryLookupSource.key("e\u{301}l"))
        #expect(DictionaryLookupSource.key("él") != DictionaryLookupSource.key("el"))
    }
    @Test func importChoicesAndColumnsPersistInAnIsolatedDomain() throws {
        let suite = "libron-preferences-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let p = LibraryPreferences(defaults: defaults)
        #expect(p.askBeforeConversion && p.backupOriginals)
        p.askBeforeConversion = false; p.backupOriginals = false; p.columns = [.language,.origin]
        let reopened = LibraryPreferences(defaults: defaults)
        #expect(!reopened.askBeforeConversion && !reopened.backupOriginals && reopened.columns == [.language,.origin])
    }
    @Test func eswordRichTextKeepsUnicodeVerseAnchorsAndRedLetters() throws {
        let page = ESwordPage(ordinal: 0, entries: [ESwordEntry(title: "1", body: "<p><span style=\"color:#ff0000\">Amor 😀</span></p>", reference: "Ge 1:1")], contents: ["Ge 1"])
        let result = try ESwordReader.project(page, request: .init(ordinal: 0, reference: "Ge 1:1"))
        #expect(result.text.contains("Amor 😀"))
        #expect(result.content?.anchors.first?.characterOffset == 0)
        let rendered = ReaderTypography.render(text: result.text, content: result.content, typography: nil).text
        #expect(rendered.string == result.text)
        let index = (rendered.string as NSString).range(of: "Amor").location
        let color = try #require((rendered.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)?.usingColorSpace(.deviceRGB))
        #expect(color.redComponent > color.greenComponent * 2 && color.redComponent > color.blueComponent * 2)
    }
    @Test func currentESwordCorpusReadsEveryFirstAndLastEntry() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_ESWORD_ROOT"] else { return }
        let snapshot = try await LibraryImporter().importDirectory(at: URL(fileURLWithPath: path))
        #expect(snapshot.resources.count == 22)
        for resource in snapshot.resources {
            let first = try await ReaderSession.read(resource, .init(ordinal: 0))
            #expect(first.sectionCount > 0 && !first.text.isEmpty)
            let last = try await ReaderSession.read(resource, .init(ordinal: first.sectionCount - 1))
            #expect(!last.text.isEmpty)
        }
    }
}

@MainActor struct MigratedLibraryCorpusTests {
    @Test func migratedEditionsRetainOriginalPagesAndDictionaryDestinations() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_MANAGED_CORPUS"] else { return }
        let catalog = try LibronCatalog.load(from: URL(fileURLWithPath: path))
        #expect(catalog.resources.count >= 429)
        for filename in ["RVR60.LSF", "rvr60.lbxlls", "spanishrv.bbli"] {
            let converted = try #require(catalog.resources.first { $0.location.lastPathComponent == filename })
            let original = LibraryResource(location: URL(fileURLWithPath: converted.id), indexLocation: converted.indexLocation.map {
                URL(fileURLWithPath: converted.id).deletingLastPathComponent().appendingPathComponent($0.lastPathComponent)
            }, title: converted.title, byteCount: converted.byteCount, format: converted.format, support: converted.support, provenance: converted.provenance)
            let request = ReaderDestination(ordinal: 0, reference: "Ge 1:1")
            let before = try await ReaderSession.read(original, request), after = try await ReaderSession.read(converted, request)
            #expect(before.text == after.text && before.content?.anchors == after.content?.anchors)
        }
        let smith = try #require(catalog.resources.first { $0.location.lastPathComponent == "smith.dcti" })
        let definition = try await DictionaryLookupSource.shared.lookup("Abel", in: smith)
        #expect(definition?.text.isEmpty == false)
        let dictionary = try #require(catalog.resources.first { $0.location.lastPathComponent == "ndbunilit.lbxlls" })
        let index = try #require(try await LibronixTopicCatalogService.shared.catalog(dictionary))
        let term = try #require(index.indexes.flatMap(\.topics).map(\.text).first { DictionaryController.singleWord($0) != nil })
        let nativeDefinition = try await DictionaryLookupSource.shared.lookup(term, in: dictionary)
        #expect(nativeDefinition?.text.isEmpty == false)
        let workspace = StudyWorkspace(); workspace.resources = catalog.resources
        let automatic = workspace.bibleGroups.filter { $0.automaticLanguage != nil }
        #expect(Set(automatic.compactMap(\.automaticLanguage)).isSuperset(of: ["es","en","pt","he"]))
        #expect(automatic.allSatisfy { !$0.members.isEmpty })
    }
}
