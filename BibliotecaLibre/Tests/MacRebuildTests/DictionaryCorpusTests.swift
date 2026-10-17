import AppKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct DictionaryCorpusTests {
    @Test func currentDictionariesHaveReusableWordIndexesAndReadRealDefinitions() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_MANAGED_CORPUS"] else { return }
        let resources = try LibronCatalog.load(from: URL(fileURLWithPath: path)).resources.filter(LibronDictionaryIndex.supports)
        var audit: [[String: String]] = []
        for resource in resources {
            do {
                let index = try await LibronDictionaryIndexService.shared.index(resource)
                #expect(!index.entries.isEmpty, "Missing dictionary entries: \(resource.title)")
                let query = resource.languages.contains("en") ? "earth" : "tierra"
                let match = try await LibronDictionaryIndexService.shared.match(query, in: resource)
                let sample = try #require(match ?? index.entries.first)
                let page = try await ReaderSession.read(resource, .init(ordinal: sample.ordinal))
                #expect(!page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty definition: \(resource.title)")
                audit.append(["title": resource.title, "entries": String(index.entries.count), "query": query,
                    "match": match?.headword ?? "", "sample": sample.headword, "sampleLength": String(page.text.count)])
            } catch {
                audit.append(["title": resource.title,"error": error.localizedDescription])
                Issue.record("Dictionary failed: \(resource.title): \(error)")
            }
        }
        if let out = ProcessInfo.processInfo.environment["LIBRONX_DICTIONARY_AUDIT"] {
            try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: out))
        }
        let workspace = StudyWorkspace(); workspace.resources = resources
        workspace.libraryGroup = "dictionaries"
        #expect(workspace.filteredResources.count == resources.count)
        #expect(workspace.dictionaryGroup.count == resources.count)
        let spanish = try #require(resources.first { $0.location.lastPathComponent == "ndbunilit.lbxlls" })
        #expect(try await DictionaryLookupSource.shared.lookup("tierra", in: spanish) != nil)
        #expect(try await DictionaryLookupSource.shared.lookup("amor", in: spanish) != nil)
        let reopened = LibronDictionaryIndexService()
        #expect(try await reopened.match("tierra", in: spanish) != nil)
        let reader = workspace.open(spanish, startReading: false)
        workspace.dictionary.lookupInside("tierra", resource: spanish, reader: reader, workspace: workspace)
        for _ in 0..<1_000 where workspace.dictionary.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!workspace.dictionary.isLoading)
        #expect(reader.dictionaryWord == "tierra" && reader.page?.text.isEmpty == false)
        #expect(workspace.dictionary.matches.count >= 4)
        workspace.cycleDictionary(reader)
        for _ in 0..<1_000 where workspace.dictionary.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reader.resource.id != spanish.id && reader.dictionaryWord == "tierra")
        workspace.dictionary.selectionChanged("una frase", workspace: workspace)
        #expect(reader.page == nil && reader.dictionaryWord.isEmpty)
    }
    @Test func queriedWindowCyclesOnlyMatchingDictionariesAndWrapsBothWays() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_MANAGED_CORPUS"] else { return }
        let workspace = StudyWorkspace()
        workspace.resources = try LibronCatalog.load(from: URL(fileURLWithPath: path)).resources
        if let bundled = ProcessInfo.processInfo.environment["LIBRONX_BUNDLED_CORPUS"] {
            workspace.resources += try BundledDictionaries.resources(at: URL(fileURLWithPath: bundled))
        }
        let all = workspace.dictionaryGroup
        let initial = try #require(all.first { $0.title.contains("Strong") })
        let reader = workspace.open(initial, startReading: false)
        func finish() async throws {
            for _ in 0..<2_000 where workspace.dictionary.isLoading { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!workspace.dictionary.isLoading)
        }
        workspace.dictionary.lookupInside("pastor", resource: initial, reader: reader, workspace: workspace)
        try await finish()
        let choices = workspace.dictionaryChoices(for: reader)
        #expect(choices.count > 1 && choices.count < all.count)
        #expect(workspace.dictionaryGroup.count == all.count)
        for resource in choices { #expect(try await LibronDictionaryIndexService.shared.match("pastor", in: resource) != nil) }
        let start = reader.resource.id
        var visited: Set<String> = []
        for _ in choices.indices {
            visited.insert(reader.resource.id)
            #expect(reader.dictionaryWord == "pastor" && reader.page?.text.isEmpty == false && reader.error == nil)
            workspace.cycleDictionary(reader)
            try await finish()
        }
        #expect(visited == Set(choices.map(\.id)) && reader.resource.id == start)
        workspace.cycleDictionary(reader, backwards: true); try await finish()
        workspace.cycleDictionary(reader); try await finish()
        #expect(reader.resource.id == start && reader.page != nil)
        reader.dictionaryWord = "unknown-new-query"
        #expect(workspace.dictionaryChoices(for: reader).isEmpty)
        workspace.cycleDictionary(reader)
        #expect(reader.resource.id == start)
        reader.dictionaryWord = ""
        #expect(workspace.dictionaryChoices(for: reader).count == all.count)
    }
    @Test func aliasesRetainAccentsAndDictionaryPanesUseReaderGeometry() {
        #expect(LibronDictionaryIndex.aliases("TIERRA, PAÍS (geografía)").contains("tierra"))
        #expect(LibronDictionaryIndex.aliases("8680\tStem  — Aphel\tSee 8817").contains("8680"))
        #expect(LibronDictionaryIndex.aliases("8680\tStem  — Aphel\tSee 8817").contains("aphel"))
        #expect(LibronDictionaryIndex.key("él") != LibronDictionaryIndex.key("el"))
        var m = LibronMetadata(title: "Dictionary", origin: "e-Sword"); m.resourceType = "Diccionario o enciclopedia"
        let resource = LibraryResource(location: URL(fileURLWithPath: "/tmp/dictionary"), title: m.title, byteCount: 0,
            format: .eSwordSQLite, support: .metadataOnly, provenance: .fileName, libron: m)
        let workspace = StudyWorkspace(); workspace.resources = [resource]
        let reader = workspace.open(resource, startReading: false)
        let original = reader.frame
        reader.showDictionary(resource, word: "tierra", page: .init(destination: .init(ordinal: 4), text: "Definición", sectionCount: 10))
        #expect(workspace.presentedReaders.contains { $0 === reader })
        #expect(reader.frame == original && reader.isDictionary && reader.dictionaryWord == "tierra")
        workspace.place(reader, in: PaneSnap.right.frame)
        #expect(reader.frame == PaneSnap.right.frame)
        reader.clearDictionaryDefinition()
        #expect(reader.page == nil && reader.dictionaryWord.isEmpty)
    }
    @Test func nativeQuickLookupAnchorsOnlySingleWords() {
        let text = ActiveTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        text.string = "tierra y cielo"
        var words: [String] = []
        text.quickLookupWord = { word, view, _ in
            #expect(view === text)
            words.append(word)
        }
        text.setSelectedRange(NSRange(location: 0, length: 6))
        text.quickLookPreviewItems(nil)
        #expect(words == ["tierra"])
        text.setSelectedRange(NSRange(location: 0, length: 14))
        text.quickLookPreviewItems(nil)
        #expect(words == ["tierra"])
    }

}
