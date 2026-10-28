import Foundation

public enum PrayerRepeat: String, Codable, CaseIterable, Sendable {
    case once, daily, weekly, monthly
}

public struct PrayerCategory: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct PrayerRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var details: String
    public var categoryID: UUID?
    public var start: ReadingDay
    public var repetition: PrayerRepeat
    /// A presentation preference, not encryption or access control.
    public var isPrivate: Bool
    public var lastPrayed: ReadingDay?
    public var answered: ReadingDay?

    public init(id: UUID = UUID(), title: String, details: String = "", categoryID: UUID? = nil,
                start: ReadingDay, repetition: PrayerRepeat = .once, isPrivate: Bool = false,
                lastPrayed: ReadingDay? = nil, answered: ReadingDay? = nil) {
        self.id = id; self.title = title; self.details = details; self.categoryID = categoryID
        self.start = start; self.repetition = repetition; self.isPrivate = isPrivate
        self.lastPrayed = lastPrayed; self.answered = answered
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 4096, details.utf8.count <= 100_000,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !details.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
            throw PersonalStateError.invalid("La oración contiene datos incompatibles.")
        }
        try start.validate()
        if let lastPrayed { try lastPrayed.validate(); guard lastPrayed >= start else { throw PersonalStateError.invalid("La oración contiene fechas incompatibles.") } }
        if let answered {
            try answered.validate()
            guard answered >= start, lastPrayed.map({ $0 <= answered }) ?? true else { throw PersonalStateError.invalid("La oración contiene fechas incompatibles.") }
        }
    }
    /// A monthly recurrence anchored on the 29th–31st uses the last day of a
    /// shorter month; the original anchor is retained in subsequent months.
    public func isDue(on day: ReadingDay) throws -> Bool {
        try validate(); try day.validate()
        guard day >= start, answered == nil else { return false }
        if repetition == .once { return lastPrayed == nil }
        if lastPrayed == day { return false }
        switch repetition {
        case .once: return false
        case .daily: return true
        case .weekly: return try start.weekday() == day.weekday()
        case .monthly:
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: 1)),
                  let days = calendar.range(of: .day, in: .month, for: date) else { throw PersonalStateError.invalid("La fecha de lectura no es válida.") }
            return day.day == min(start.day, days.count)
        }
    }
    public mutating func markPrayed(on day: ReadingDay) throws {
        guard try isDue(on: day) else { throw PersonalStateError.invalid("La oración no está pendiente para esta fecha.") }
        lastPrayed = day
    }
    public mutating func setAnswered(on day: ReadingDay?) throws {
        var next = self; next.answered = day; try next.validate(); self = next
    }
}

public struct PrayerJournal: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var categories: [PrayerCategory] = []
    public var requests: [PrayerRequest] = []
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard categories.count <= 500, requests.count <= 100_000,
              Set(categories.map(\.id)).count == categories.count,
              Set(requests.map(\.id)).count == requests.count else { throw PersonalStateError.invalid("La lista de oración contiene datos incompatibles.") }
        let names = categories.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              Set(names.map { $0.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }).count == names.count else {
            throw PersonalStateError.invalid("Las categorías de oración no son válidas o están duplicadas.")
        }
        let categoryIDs = Set(categories.map(\.id))
        for request in requests {
            try request.validate()
            if let category = request.categoryID, !categoryIDs.contains(category) { throw PersonalStateError.invalid("La categoría de la oración ya no existe.") }
        }
    }
    public mutating func removeCategory(_ id: UUID) throws {
        guard categories.contains(where: { $0.id == id }) else { throw PersonalStateError.concurrentChange }
        guard !requests.contains(where: { $0.categoryID == id }) else { throw PersonalStateError.invalid("La categoría contiene oraciones.") }
        categories.removeAll { $0.id == id }
    }
}
