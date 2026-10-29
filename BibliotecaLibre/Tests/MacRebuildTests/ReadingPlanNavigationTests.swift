import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

struct ReadingPlanNavigationTests {
    actor Source: LibrarySearchContentProvider {
        let explicit: Bool
        var changed = false
        init(explicit: Bool = false) { self.explicit = explicit }
        func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
            .init(articles: [.init(sectionOrdinal: 0, title: "Owned")])
        }
        func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor, prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
            var text = "😀 owned heading\n", verses: [LibrarySearchBibleVerse] = []
            for (plain, qualified, body) in [("John1:1", "bible+owned.64.1.1", "Own beginning"), ("John3:1", "bible+owned.64.3.1", "Own chapter"), ("John3:16", "bible+owned.64.3.16", "Own selected text") ] {
                let key = try #require(LegacyPassageQuery.parse(plain)).normalizedKey
                verses.append(.init(reference: explicit ? qualified : plain, normalizedReference: key, range: .init(location: text.utf16.count, length: body.utf16.count)))
                text += body + "\n"
            }
            return .init(text: text, bibleVerses: verses)
        }
        func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws {
            if changed { throw LegacyIndicesError.sourceChanged }
        }
        func change() { changed = true }
    }
    private func resource() -> LibraryResource {
        .init(location: URL(fileURLWithPath: "/owned/unrelated-name.LSF"), title: "Owned", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
    }
    @Test func rangeChapterAndBookStartAtVerifiedSourceCoordinates() async throws {
        let navigator = ReadingPlanNavigator(provider: Source()), book = resource()
        let range = try await navigator.target("John 3:16-18", in: book)
        #expect(range.resource == book && range.verse.key == "jn 3:16" && range.verse.text == "Own selected text")
        #expect(range.verse.sourceRange.location > "😀 owned heading\n".utf16.count)
        #expect(try await navigator.target("John 3", in: book).verse.key == "jn 3:1")
        #expect(try await navigator.target("John", in: book).verse.key == "jn 1:1")
        await #expect(throws: (any Error).self) { try await navigator.target("not a passage", in: book) }
    }
    @Test func explicitEditionIsVerifiedAgainstTheSourceAndCannotBeSatisfiedByAnotherCitation() async throws {
        let navigator = ReadingPlanNavigator(provider: Source(explicit: true)), book = resource()
        let target = try await navigator.target("John 3:16(owned)", in: book)
        #expect(target.verse.reference == "bible+owned.64.3.16")
        await #expect(throws: PersonalStateError.self) { try await navigator.target("John 3:16(other)", in: book) }
        await #expect(throws: PersonalStateError.self) { try await navigator.target("John 3:16(other); John 3:16", in: book) }
        await #expect(throws: PersonalStateError.self) { try await navigator.target("John 3:99(owned)", in: book) }
    }
    @Test func changedSourcesAndCancellationNeverProduceAnOpeningTarget() async throws {
        let source = Source(), navigator = ReadingPlanNavigator(provider: source), book = resource()
        await source.change()
        await #expect(throws: PersonalStateError.self) { try await navigator.target("John 3:16", in: book) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ReadingPlanNavigator(provider: Source()).target("John 3:16", in: book)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
