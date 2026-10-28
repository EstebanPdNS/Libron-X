import Foundation
import Testing
@testable import LibronixCore

@Suite struct ReadingPlanTests {
    @Test func multiplePassagesKeepTheirOrderAndShareOnlySelectedDays() throws {
        let start = try ReadingDay(year: 2024, month: 2, day: 28)
        let passages = ["John 1", "John 2", "John 3", "John 4", "John 5"]
        let plan = try ReadingPlan.schedule(title: "Own", references: passages, start: start, weekdays: [2, 5], passagesPerDay: 2)
        let thursday = try ReadingDay(year: 2024, month: 2, day: 29), monday = try ReadingDay(year: 2024, month: 3, day: 4), next = try ReadingDay(year: 2024, month: 3, day: 7)
        #expect(plan.readings.map(\.day) == [thursday, thursday, monday, monday, next])
        #expect(plan.visibleReadings(hideCompleted: false).map(\.reference) == passages)
        let calendar = String(decoding: try ReadingPlanCalendar.export(plan, timestamp: Date(timeIntervalSince1970: 0)), as: UTF8.self)
        #expect(calendar.components(separatedBy: "DTSTART;VALUE=DATE:20240229").count == 3)
        #expect(calendar.components(separatedBy: "DTSTART;VALUE=DATE:20240304").count == 3)
        #expect(throws: PersonalStateError.self) { try ReadingPlan.schedule(title: "Own", references: passages, start: start, weekdays: [2], passagesPerDay: 0) }
        #expect(throws: PersonalStateError.self) { try ReadingPlan.schedule(title: "Own", references: passages, start: start, weekdays: [2], passagesPerDay: 101) }
    }
    @Test func scheduleUsesCivilDaysAndSkipsUnselectedWeekdays() throws {
        let start = try ReadingDay(year: 2024, month: 2, day: 28)
        let plan = try ReadingPlan.schedule(title: "Own plan", references: ["John 1", "John 2", "John 3"], start: start, weekdays: [2, 4, 6])
        #expect(plan.readings.map(\.day) == [try ReadingDay(year: 2024, month: 2, day: 28), try ReadingDay(year: 2024, month: 3, day: 1), try ReadingDay(year: 2024, month: 3, day: 4)])
        let decoded = try JSONDecoder().decode(ReadingPlan.self, from: JSONEncoder().encode(plan))
        try decoded.validate(); #expect(decoded == plan)
        var done = decoded; done.readings[1].completed = true
        #expect(done.visibleReadings(hideCompleted: true).map(\.reference) == ["John 1", "John 3"])
        #expect(done.visibleReadings(hideCompleted: false).count == 3)
        var duplicate = plan; duplicate.id = UUID()
        var collection = ReadingPlans(); collection.plans = [plan, duplicate]
        #expect(throws: PersonalStateError.self) { try collection.validate() }
    }
    @Test func invalidDatesPassagesAndCorruptDataAreRejected() throws {
        #expect(throws: PersonalStateError.self) { try ReadingDay(year: 2023, month: 2, day: 29) }
        let start = try ReadingDay(year: 2024, month: 1, day: 1)
        #expect(throws: PersonalStateError.self) { try ReadingPlan.schedule(title: "Own", references: ["John 1"], start: start, weekdays: []) }
        #expect(throws: (any Error).self) { try ReadingPlan.schedule(title: "Own", references: ["not a passage"], start: start, weekdays: [1]) }
        let decoded = try JSONDecoder().decode(ReadingDay.self, from: Data(#"{"year":2024,"month":2,"day":30}"#.utf8))
        #expect(throws: PersonalStateError.self) { try decoded.weekday() }
        #expect(throws: PersonalStateError.self) { try decoded.adding(days: 1) }
    }
    @Test func calendarExportUsesStableAllDayEventsEscapingAndUtf8Folding() throws {
        let start = try ReadingDay(year: 2024, month: 3, day: 10)
        let title = String(repeating: "É", count: 45) + ",a; b\\c\nnext"
        let plan = try ReadingPlan.schedule(title: title, references: ["John 3:16", "John 4"], start: start, weekdays: Set(1...7))
        let exported = String(decoding: try ReadingPlanCalendar.export(plan, timestamp: Date(timeIntervalSince1970: 0)), as: UTF8.self)
        let lines = exported.components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.utf8.count <= 75 })
        let unfolded = exported.replacingOccurrences(of: "\r\n ", with: "")
        #expect(unfolded.contains("DTSTAMP:19700101T000000Z\r\n"))
        #expect(unfolded.contains("DTSTART;VALUE=DATE:20240310\r\nDTEND;VALUE=DATE:20240311"))
        #expect(unfolded.contains("SUMMARY:" + String(repeating: "É", count: 45) + "\\,a\\; b\\\\c\\nnext"))
        #expect(unfolded.contains("DESCRIPTION:John 3:16"))
        #expect(unfolded.contains("UID:\(plan.readings[0].id.uuidString.lowercased())@libron-x.local"))
        #expect(unfolded.hasSuffix("END:VCALENDAR\r\n"))
    }
}
