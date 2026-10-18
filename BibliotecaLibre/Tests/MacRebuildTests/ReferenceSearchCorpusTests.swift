import AppKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct ReferenceSearchCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_REFERENCE_SEARCH_CORPUS"] != nil))
    func originalLinkedNotesExposeEveryCheckedBibleDestinationToReferenceSearch() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_REFERENCE_SEARCH_CORPUS"]))
        let catalog = try LibronCatalog.load(from: root).resources
        let names = ["RVR60.LSF", "rvr60.lbxlls", "RVR95.LSF", "LBLA95.lbxlls", "NVI.lbxlls"]
        var checked = 0, notes = 0
        for name in names {
            let resource = try #require(catalog.first { $0.location.lastPathComponent == name })
            let page = try await ReaderSession.read(resource, .init(ordinal: 0, reference: "Ge4:1"))
            let ordinals = Set(page.inlineLinks.compactMap(\.sectionOrdinal))
            #expect(!ordinals.isEmpty)
            let provider = WorkspaceSearchReader(), prepared = try await provider.prepare(resource)
            for ordinal in ordinals.sorted() {
                let article = try #require(prepared.articles.first { $0.sectionOrdinal == ordinal })
                let decoded = try await provider.read(resource, article: article, prepared: prepared)
                let visible = try await ReaderSession.read(resource, .init(ordinal: ordinal))
                let links = visible.inlineLinks.compactMap(BibleReferenceSourceLink.init)
                #expect(decoded.text == visible.text && decoded.referenceLinks == links)
                let mentions = try BibleReferenceMentions.extract(decoded.text, links: links).filter { $0.origin == .explicitLink }
                #expect(mentions.count == links.count)
                for link in links {
                    let query = try BibleReferenceQuery.parse(link.target)
                    #expect(mentions.contains { $0.range == link.range && query.matches($0) })
                    checked += 1
                }
                notes += 1
            }
            try await provider.verifyUnchanged(resource, prepared: prepared)
        }
        #expect(checked == 62)
        print("Reference search corpus: \(names.count) original resources, \(notes) linked note articles, \(checked) checked Bible destinations")
    }
}
