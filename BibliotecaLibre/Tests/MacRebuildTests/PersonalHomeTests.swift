import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@Suite struct PersonalHomeTests {
    @Test func readingsUseTheLocalCivilDayAndKeepTheirOwnPlans() throws {
        let today = try ReadingDay(year: 2026, month: 10, day: 28)
        let tomorrow = try today.adding(days: 1)
        let a = ScheduledReading(day: today, reference: "Juan 1:1")
        let b = ScheduledReading(day: today, reference: "Juan 1:2", completed: true)
        let c = ScheduledReading(day: tomorrow, reference: "Juan 1:3")
        let first = ReadingPlan(title: "One", readings: [a, c]), second = ReadingPlan(title: "Two", readings: [b])
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-29T02:00:00Z"))
        let west = try #require(TimeZone(secondsFromGMT: -7 * 3600))
        let result = PersonalHomeSummary.today(plans: [first, second], date: date, timeZone: west)
        #expect(result.map(\.reading.id) == [a.id, b.id])
        #expect(result.map(\.plan.id) == [first.id, second.id])
        #expect(result[1].reading.completed)
        #expect(PersonalHomeSummary.today(plans: [first, second], date: date, timeZone: .gmt).map(\.reading.id) == [c.id])
    }
}
