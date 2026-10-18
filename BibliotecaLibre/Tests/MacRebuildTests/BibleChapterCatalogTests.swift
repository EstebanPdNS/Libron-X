import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct BibleChapterCatalogTests {
    @Test func observedPositionsMergeAliasesWithoutInventingChapters() {
        let books = BibleChapterBook.collect(["Ge.1", "Gen 3:2", "Génesis 1:5", "Jn 4:1", "not a reference"])
        #expect(BibleChapterCatalog.chapterReference(label: "Ge.51", title: "") == nil)
        #expect(BibleChapterCatalog.chapterReference(label: "FTN.GE.51", title: "Chapter 51") == nil)
        #expect(BibleChapterCatalog.chapterReference(label: "ESV.GE.3", title: "Chapter 3") == "GE 3:1")
        #expect(BibleChapterCatalog.chapterReference(label: "Ge.CH50", title: "Capítulo 50") == "Ge 50:1")
        #expect(books.map(\.id) == ["ge", "jn"])
        #expect(books[0].chapters == [1,3])
        #expect(LegacyPassageQuery.navigationInput(books[0].reference(chapter:3))?.normalizedKey == "ge 3:2")
        #expect(books[0].title(language: .spanish) == "Génesis")
        #expect(LegacyPassageQuery.navigationInput(books[1].reference(chapter: 4))?.normalizedKey == "jn 4:1")
    }
    @Test func realBibleSelectorsContainObservedBooksAndChapters() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_MANAGED_CORPUS"] else { return }
        let resources = try LibronCatalog.load(from: URL(fileURLWithPath: path)).resources
        for filename in ["RVR60.LSF", "ESV.lbxlls", "spanishrv.bbli"] {
            let resource = try #require(resources.first { $0.location.lastPathComponent.lowercased() == filename.lowercased() })
            let books = try await BibleChapterCatalog.shared.books(in: resource)
            print("Chapter selector: \(filename) books=\(books.count) chapters=\(books.reduce(0) { $0 + $1.chapters.count })")
            #expect(books.count >= 66, "Missing book positions in \(filename)")
            let genesis = try #require(books.first { $0.id == "ge" })
            #expect(genesis.chapters == Array(1...50))
            let john = try #require(books.first { $0.id == "jn" })
            #expect(john.chapters.contains(3))
            let page = try await ReaderSession.read(resource, .init(ordinal: 0, reference: john.reference(chapter: 3)))
            #expect(page.text.isEmpty == false)
        }
    }
    @Test func everyInstalledBibleHasNavigableObservedChapterSelectors() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_MANAGED_CORPUS"] else { return }
        let resources = try LibronCatalog.load(from: URL(fileURLWithPath: path)).resources
            .filter { $0.libron?.resourceType == "Biblia" }
        #expect(!resources.isEmpty)
        for resource in resources {
            let books = try await BibleChapterCatalog.shared.books(in: resource)
            #expect(!books.isEmpty, "No chapter selectors: \(resource.title)")
            for book in books {
                #expect(!book.chapters.isEmpty, "Empty book: \(resource.title) / \(book.id)")
                for chapter in book.chapters {
                    #expect(book.sourceOrdinals?[chapter] != nil || LegacyPassageQuery.navigationInput(book.reference(chapter: chapter)) != nil,
                        "Invalid navigation: \(resource.title) / \(book.reference(chapter: chapter))")
                }
            }
            if let opaque = books.first(where: { $0.sourceOrdinals != nil }),
               let ordinal = opaque.sourceOrdinals?[opaque.chapters[0]] {
                let page = try await ReaderSession.read(resource, .init(ordinal: ordinal))
                #expect(page.destination.ordinal == ordinal)
                #expect(!page.text.isEmpty)
            }
            print("Bible selectors: \(resource.location.lastPathComponent) books=\(books.count) chapters=\(books.reduce(0) { $0 + $1.chapters.count })")
        }
    }

}
