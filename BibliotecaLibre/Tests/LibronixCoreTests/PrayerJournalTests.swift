import Foundation
import Testing
@testable import LibronixCore

struct PrayerJournalTests {
    @Test func recurrenceUsesCivilDatesAndMonthlyAnchors() throws {
        let start = try ReadingDay(year: 2024, month: 1, day: 31)
        var request = PrayerRequest(title: "Owned example", start: start, repetition: .monthly, isPrivate: true)
        #expect(try request.isDue(on: start))
        #expect(try request.isDue(on: ReadingDay(year: 2024, month: 2, day: 29)))
        #expect(try request.isDue(on: ReadingDay(year: 2025, month: 2, day: 28)))
        #expect(!(try request.isDue(on: ReadingDay(year: 2024, month: 3, day: 30))))
        #expect(try request.isDue(on: ReadingDay(year: 2024, month: 3, day: 31)))
        try request.markPrayed(on: start)
        #expect(!(try request.isDue(on: start)))
        #expect(throws: (any Error).self) { try request.markPrayed(on: start) }
        try request.setAnswered(on: ReadingDay(year: 2024, month: 2, day: 1))
        #expect(!(try request.isDue(on: ReadingDay(year: 2024, month: 2, day: 29))))
        try request.setAnswered(on: nil)
        #expect(try request.isDue(on: ReadingDay(year: 2024, month: 2, day: 29)))
        #expect(request.isPrivate && request.lastPrayed == start)
    }
    @Test func weeklyAndOnceRespectStartAndCompletion() throws {
        let start = try ReadingDay(year: 2024, month: 3, day: 10)
        var weekly = PrayerRequest(title: "Weekly", start: start, repetition: .weekly)
        #expect(!(try weekly.isDue(on: ReadingDay(year: 2024, month: 3, day: 9))))
        #expect(try weekly.isDue(on: ReadingDay(year: 2024, month: 3, day: 17)))
        #expect(!(try weekly.isDue(on: ReadingDay(year: 2024, month: 3, day: 18))))
        try weekly.markPrayed(on: start)
        #expect(try weekly.isDue(on: ReadingDay(year: 2024, month: 3, day: 17)))
        var once = PrayerRequest(title: "Once", start: start)
        #expect(try once.isDue(on: ReadingDay(year: 2024, month: 3, day: 18)))
        try once.markPrayed(on: start)
        #expect(!(try once.isDue(on: ReadingDay(year: 2024, month: 3, day: 18))))
    }
    @Test func categoriesAndReferencesAreValidatedWithoutDiscardingRequests() throws {
        let category = PrayerCategory(name: "Family"), date = try ReadingDay(year: 2025, month: 1, day: 1)
        var journal = PrayerJournal(); journal.categories = [category]
        journal.requests = [.init(title: "Owned", categoryID: category.id, start: date)]
        try journal.validate()
        #expect(throws: (any Error).self) { try journal.removeCategory(category.id) }
        #expect(journal.categories.count == 1 && journal.requests.count == 1)
        journal.categories.append(.init(name: "family"))
        #expect(throws: (any Error).self) { try journal.validate() }
        journal.categories.removeLast(); journal.requests[0].categoryID = UUID()
        #expect(throws: (any Error).self) { try journal.validate() }
    }
}
