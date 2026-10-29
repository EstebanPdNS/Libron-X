import Foundation

/// One budget for a prepared copy, shared by body, templates, notes and separators.
/// The element bound also caps documents made of tiny, independently styled runs.
struct BibleCopyOutputBudget {
    static let maximumUTF16Units = 16_000_000
    static let maximumElements = 100_000
    private(set) var remainingUTF16Units: Int
    private var remainingElements = Self.maximumElements

    init(maximumUTF16Units: Int) throws {
        guard (0...Self.maximumUTF16Units).contains(maximumUTF16Units) else { throw BibleCopyError.limitExceeded }
        remainingUTF16Units = maximumUTF16Units
    }

    /// Counts come from owned strings and emitted elements, never unchecked input.
    mutating func consume(units: Int = 0, elements: Int = 0) throws {
        guard units <= remainingUTF16Units, elements <= remainingElements else { throw BibleCopyError.limitExceeded }
        remainingUTF16Units -= units
        remainingElements -= elements
    }
}
