import Foundation

/// A civil date, independent of the user's current time zone and DST.
public struct ReadingDay: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    public init(year: Int, month: Int, day: Int) throws {
        self.year = year; self.month = month; self.day = day
        try validate()
    }
    public func validate() throws {
        guard (1900...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = Self.calendar.date(from: DateComponents(year: year, month: month, day: day)),
              Self.calendar.component(.year, from: date) == year,
              Self.calendar.component(.month, from: date) == month,
              Self.calendar.component(.day, from: date) == day else {
            throw PersonalStateError.invalid("La fecha de lectura no es válida.")
        }
    }
    private var date: Date { Self.calendar.date(from: DateComponents(year: year, month: month, day: day))! }
    public func weekday() throws -> Int { try validate(); return Self.calendar.component(.weekday, from: date) }
    public func adding(days: Int) throws -> Self {
        try validate()
        guard let next = Self.calendar.date(byAdding: .day, value: days, to: date) else { throw PersonalStateError.invalid("La fecha de lectura no es válida.") }
        return try Self(year: Self.calendar.component(.year, from: next), month: Self.calendar.component(.month, from: next), day: Self.calendar.component(.day, from: next))
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
    public var calendarValue: String { String(format: "%04d%02d%02d", year, month, day) }
}

public struct ScheduledReading: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var day: ReadingDay
    public var reference: String
    public var completed: Bool
    public init(id: UUID = UUID(), day: ReadingDay, reference: String, completed: Bool = false) {
        self.id = id; self.day = day; self.reference = reference; self.completed = completed
    }
}

public struct ReadingPlan: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var readings: [ScheduledReading]
    public init(id: UUID = UUID(), title: String, readings: [ScheduledReading]) {
        self.id = id; self.title = title; self.readings = readings
    }
    /// Distribute explicit passages in their original order on selected days.
    /// Weekdays use Foundation's Gregorian convention: Sunday 1, Saturday 7.
    public static func schedule(title: String, references: [String], start: ReadingDay, weekdays: Set<Int>, passagesPerDay: Int = 1) throws -> Self {
        try start.validate()
        guard !references.isEmpty, references.count <= 10_000, !weekdays.isEmpty,
              weekdays.allSatisfy({ (1...7).contains($0) }), (1...100).contains(passagesPerDay) else { throw PersonalStateError.invalid("El plan necesita pasajes y días de lectura válidos.") }
        var day = start, readings: [ScheduledReading] = []
        for (index, raw) in references.enumerated() {
            let reference = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try BibleReferenceQuery.parse(reference)
            while try !weekdays.contains(day.weekday()) { day = try day.adding(days: 1) }
            readings.append(.init(day: day, reference: reference))
            if index < references.count - 1 && (index + 1).isMultiple(of: passagesPerDay) { day = try day.adding(days: 1) }
        }
        let result = Self(title: title.trimmingCharacters(in: .whitespacesAndNewlines), readings: readings)
        try result.validate(); return result
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 4096,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" }),
              !readings.isEmpty, readings.count <= 10_000, Set(readings.map(\.id)).count == readings.count else {
            throw PersonalStateError.invalid("El plan de lectura contiene datos incompatibles.")
        }
        for reading in readings {
            try reading.day.validate()
            _ = try BibleReferenceQuery.parse(reading.reference)
        }
    }
    public func visibleReadings(hideCompleted: Bool) -> [ScheduledReading] {
        readings.enumerated().filter { !hideCompleted || !$0.element.completed }
            .sorted { $0.element.day == $1.element.day ? $0.offset < $1.offset : $0.element.day < $1.element.day }.map(\.element)
    }
}

public struct ReadingPlans: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var plans: [ReadingPlan] = []
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard plans.count <= 100, Set(plans.map(\.id)).count == plans.count else { throw PersonalStateError.invalid("Los planes de lectura contienen datos incompatibles.") }
        let entries = plans.flatMap(\.readings)
        guard Set(entries.map(\.id)).count == entries.count else { throw PersonalStateError.invalid("Los planes de lectura contienen datos incompatibles.") }
        for plan in plans { try plan.validate() }
    }
}
