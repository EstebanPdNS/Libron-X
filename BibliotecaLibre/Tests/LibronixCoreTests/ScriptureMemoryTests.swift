import Foundation
import Testing
@testable import LibronixCore

struct ScriptureMemoryTests {
    @Test func exactPracticeRecordsProgressWithoutInventingText() throws {
        var card = ScriptureMemoryCard(reference: "Jn 1:1", passage: "En el principio.\nPalabra", source: "User transcription")
        let today = try ReadingDay(year: 2026, month: 10, day: 28)
        #expect(try card.record(answer: "EN EL  PRINCIPIO. palabra", on: today))
        #expect(!(try card.record(answer: "En el principio palabra", on: today)))
        #expect(card.attempts == 2 && card.correct == 1 && card.lastPracticed == today)
        #expect(throws: (any Error).self) { try card.record(answer: "", on: today) }
        #expect(throws: (any Error).self) { try card.record(answer: "word", on: ReadingDay(year: 2026, month: 10, day: 27)) }
        #expect(card.attempts == 2 && card.passage == "En el principio.\nPalabra")
    }
    @Test func validatesAndRoundTrips() throws {
        var memory = ScriptureMemory(); memory.cards = [.init(reference: "Jn 1:1", passage: "Texto")]
        try memory.validate()
        let loaded = try JSONDecoder().decode(ScriptureMemory.self, from: JSONEncoder().encode(memory))
        #expect(loaded == memory)
        memory.cards.append(memory.cards[0]); #expect(throws: (any Error).self) { try memory.validate() }
    }
    @Test func editingRetainsProgressOnlyForUnchangedSourceMaterial() throws {
        let resource = LibraryResource(location: URL(fileURLWithPath: "/owned-a.LSF"), title: "Owned", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        var card = ScriptureMemoryCard(reference: "John1:1", passage: "Owned text", source: "Owned", sourceEdition: .init(resource))
        let day = try ReadingDay(year: 2026, month: 10, day: 29)
        _ = try card.record(answer: "OWNED TEXT", on: day)
        let unchanged = try card.edited(reference: card.reference, passage: card.passage, source: card.source, loadedSource: card)
        #expect(unchanged == card && unchanged.correct == 1)
        let manual = try card.edited(reference: card.reference, passage: "Edited transcription", source: card.source, loadedSource: card)
        #expect(manual.id == card.id && manual.sourceEdition == nil && manual.attempts == 0 && manual.lastPracticed == nil)
        let otherResource = LibraryResource(location: URL(fileURLWithPath: "/owned-b.LSF"), title: resource.title, byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        var other = card; other.sourceEdition = .init(otherResource)
        let changedEdition = try card.edited(reference: card.reference, passage: card.passage, source: card.source, loadedSource: other)
        #expect(changedEdition.sourceEdition?.resourceID == otherResource.id && changedEdition.attempts == 0)
        // The saved exercise remains usable without resolving the library source.
        var offline = unchanged
        #expect(try offline.record(answer: offline.passage, on: day))
        #expect(offline.correct == 2)
    }
    @Test(arguments: [false, true])
    func sourceOutputBudgetIncludesEveryVerseAndSeparator(overLimit: Bool) throws {
        let resource = LibraryResource(location: URL(fileURLWithPath: "/owned.LSF"), title: "Owned", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        let bodies = [String(repeating: "x", count: overLimit ? 32000 : 31999), String(repeating: "y", count: 32000)]
        let verses: [BibleCopyVerse] = try bodies.enumerated().map { index, body in
            let query = try #require(LegacyPassageQuery.parse("John 1:\(index + 1)"))
            let range = SearchTextRange(location: 0, length: body.utf16.count)
            return .init(address: .init(query), sourceReference: query.displayReference,
                source: .init(sectionOrdinal: index, decodedTextSHA256: LibrarySearchService.textFingerprint(body), selectedRange: range),
                paragraphKey: String(index), paragraphStyle: nil,
                fragments: [.init(text: body, style: nil, sourceRange: range, footnote: nil, isBibleText: true, isVerseNumber: false)])
        }
        let document = BibleCopyDocument(resourceID: resource.id, passage: try .parse("John 1:1-2"), title: resource.title, abbreviation: "Own",
            verses: verses, footnotes: [], citation: "", typography: .init(version: 1, fontGroupVersion: 1, fontGroups: [], characterStyles: [], paragraphStyles: [], opaqueTail: Data()),
            sources: verses.map(\.source), fullParagraphs: [], sourceLanguages: ["en"])
        if overLimit {
            #expect(throws: PersonalStateError.self) { try ScriptureMemorySource.card(document: document, resource: resource) }
        } else {
            let card = try ScriptureMemorySource.card(document: document, resource: resource)
            #expect(card.passage.utf8.count == 64000 && card.reference == "John 1:1-2" && card.sourceEdition?.resourceID == resource.id)
        }
    }

}
