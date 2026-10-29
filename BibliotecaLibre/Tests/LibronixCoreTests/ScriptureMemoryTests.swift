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
}
