import Foundation

/// An e-Sword devotional directory uses recurring Gregorian month/day labels.
/// A missing or ambiguous day must never resolve to an unrelated entry.
public struct DevotionalDirectory: Sendable {
    private struct MonthDay: Hashable, Sendable {
        let month: Int
        let day: Int
    }
    private let ordinals: [MonthDay: Int]
    private let datesByOrdinal: [Int: MonthDay]

    public init(entries: [(ordinal: Int, label: String)]) throws {
        guard !entries.isEmpty, entries.count <= 366 else { throw DevotionalDirectoryError.invalidDirectory }
        var dates: [MonthDay: Int] = [:], seenOrdinals = Set<Int>()
        for entry in entries {
            let parts = entry.label.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  let month = Int(parts[0]), let day = Int(parts[1]),
                  (try? ReadingDay(year: 2000, month: month, day: day)) != nil,
                  entry.ordinal >= 0, seenOrdinals.insert(entry.ordinal).inserted else {
                throw DevotionalDirectoryError.invalidDirectory
            }
            guard dates.updateValue(entry.ordinal, forKey: .init(month: month, day: day)) == nil else {
                throw DevotionalDirectoryError.duplicateDate
            }
        }
        ordinals = dates
        datesByOrdinal = Dictionary(uniqueKeysWithValues: dates.map { ($0.value, $0.key) })
    }

    public func ordinal(for date: ReadingDay) throws -> Int? {
        try date.validate()
        return ordinals[.init(month: date.month, day: date.day)]
    }
    /// A leap-day entry may need a nearby leap year to represent its date in a picker.
    public func day(forOrdinal ordinal: Int, preferredYear: Int) -> ReadingDay? {
        guard let value = datesByOrdinal[ordinal], (1900...9999).contains(preferredYear) else { return nil }
        for distance in 0...8 {
            for year in distance == 0 ? [preferredYear] : [preferredYear - distance, preferredYear + distance] {
                if let date = try? ReadingDay(year: year, month: value.month, day: value.day) { return date }
            }
        }
        return nil
    }
}

public enum DevotionalDirectoryError: Error, Equatable, Sendable {
    case invalidDirectory
    case duplicateDate
}
