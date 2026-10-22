import Foundation
import LibronixCore

/// The table and the library's sort picker compare exactly the displayed values.
/// Capture the interface language so comparison never needs main-actor state.
struct LibraryResourceSort: SortComparator {
    var field: LibraryField
    var order: SortOrder
    let language: AppLanguage
    @MainActor init(_ field: LibraryField, order: SortOrder = .forward) {
        self.field = field; self.order = order; self.language = AppPreferences.shared.language
    }
    func compare(_ lhs: LibraryResource, _ rhs: LibraryResource) -> ComparisonResult {
        let result = field.value(lhs, language: language).localizedStandardCompare(field.value(rhs, language: language))
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

extension Array where Element == LibraryResource {
    func sortedForLibrary(using comparators: [LibraryResourceSort]) -> Self {
        sorted { lhs, rhs in
            for comparator in comparators {
                let result = comparator.compare(lhs, rhs)
                if result != .orderedSame { return result == .orderedAscending }
            }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            return titleOrder == .orderedSame ? lhs.id < rhs.id : titleOrder == .orderedAscending
        }
    }
}
