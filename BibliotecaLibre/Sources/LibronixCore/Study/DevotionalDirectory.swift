import Foundation

/// An e-Sword devotional directory uses recurring Gregorian month/day labels.
/// A missing or ambiguous day must never resolve to an unrelated entry.
public struct DevotionalDirectory: Sendable {
    private struct MonthDay: Hashable, Sendable {
        let month: Int
        let day: Int
    }
    private let ordinals: [MonthDay: Int]

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
    }

    public func ordinal(for date: ReadingDay) throws -> Int? {
        try date.validate()
        return ordinals[.init(month: date.month, day: date.day)]
    }
}

public enum DevotionalDirectoryError: Error, Equatable, Sendable {
    case invalidDirectory
    case duplicateDate
}
