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
    public var edition: StudyBibleEdition?
    public init(id: UUID = UUID(), title: String, readings: [ScheduledReading], edition: StudyBibleEdition? = nil) {
        self.id = id; self.title = title; self.readings = readings; self.edition = edition
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
            try Task.checkCancellation()
            while try !weekdays.contains(day.weekday()) { day = try day.adding(days: 1) }
            readings.append(.init(day: day, reference: reference))
            if index < references.count - 1 && (index + 1).isMultiple(of: passagesPerDay) { day = try day.adding(days: 1) }
        }
        let result = Self(title: title.trimmingCharacters(in: .whitespacesAndNewlines), readings: readings)
        try result.validate(); return result
    }
    /// Balance explicit passages over eligible civil dates without inventing a
    /// Bible's chapter lengths. Sparse schedules span the eligible interval.
    public static func schedule(title: String, references: [String], start: ReadingDay, end: ReadingDay,
                                weekdays: Set<Int>) throws -> Self {
        try start.validate(); try end.validate()
        guard start <= end, !references.isEmpty, references.count <= 10_000, !weekdays.isEmpty,
              weekdays.allSatisfy({ (1...7).contains($0) }) else {
            throw PersonalStateError.invalid("El plan necesita pasajes y días de lectura válidos.")
        }
        var day = start, dates: [ReadingDay] = [], examined = 0
        while true {
            try Task.checkCancellation()
            guard examined < 10_000 else { throw PersonalStateError.invalid("El intervalo del plan supera los 10.000 días.") }
            examined += 1
            if try weekdays.contains(day.weekday()) { dates.append(day) }
            if day == end { break }
            day = try day.adding(days: 1)
        }
        guard !dates.isEmpty else { throw PersonalStateError.invalid("El plan necesita pasajes y días de lectura válidos.") }
        let readings = try references.enumerated().map { index, raw -> ScheduledReading in
            try Task.checkCancellation()
            let position: Int
            if references.count >= dates.count { position = index * dates.count / references.count }
            else { position = references.count == 1 ? 0 : index * (dates.count - 1) / (references.count - 1) }
            return .init(day: dates[position], reference: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let plan = Self(title: title.trimmingCharacters(in: .whitespacesAndNewlines), readings: readings)
        try plan.validate(); return plan
    }
    public func validate() throws {
        try edition?.validate()
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 4096,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" }),
              !readings.isEmpty, readings.count <= 10_000, Set(readings.map(\.id)).count == readings.count else {
            throw PersonalStateError.invalid("El plan de lectura contiene datos incompatibles.")
        }
        for reading in readings {
            try Task.checkCancellation()
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
        guard (1...2).contains(schemaVersion) else { throw PersonalStateError.futureVersion }
        guard schemaVersion >= 2 || plans.allSatisfy({ $0.edition == nil }) else {
            throw PersonalStateError.invalid("La edición del plan requiere la versión 2 de los planes de lectura.")
        }
        guard plans.count <= 100, Set(plans.map(\.id)).count == plans.count else { throw PersonalStateError.invalid("Los planes de lectura contienen datos incompatibles.") }
        let entries = plans.flatMap(\.readings)
        guard Set(entries.map(\.id)).count == entries.count else { throw PersonalStateError.invalid("Los planes de lectura contienen datos incompatibles.") }
        for plan in plans { try plan.validate() }
    }
}
