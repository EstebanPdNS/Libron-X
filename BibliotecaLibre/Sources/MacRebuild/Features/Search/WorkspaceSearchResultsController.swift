import Foundation
import Observation
import LibronixCore

enum WorkspaceSearchResultFocus: Hashable, Sendable {
    case automatic, reader(SearchTextRange), external(SearchField, Int, SearchTextRange), summary
    func isValid(for result: LibrarySearchResult) -> Bool {
        switch self {
        case .automatic: true
        case .reader(let range): result.hits.contains { $0.range == range }
        case .external(let field, let index, let range): result.externalHits.contains { $0.field == field && $0.valueIndex == index && $0.range == range }
        case .summary: result.hits.isEmpty && result.externalHits.isEmpty
        }
    }
}
enum WorkspaceSearchResultLayout: String, CaseIterable { case context, aligned }
enum WorkspaceSearchResultGrouping: String, CaseIterable { case none, resource }
enum WorkspaceSearchResultOrder: String, CaseIterable { case source, titleAscending, titleDescending, mostHits }

struct WorkspaceSearchContextParts: Hashable {
    let before: String
    let match: String
    let after: String
    let omittedBefore: Bool
    let omittedAfter: Bool
    let partialStart: Bool
    let partialEnd: Bool
    static func make(text: String, extent: SearchTextRange, focus: SearchTextRange, omittedBefore: Bool, omittedAfter: Bool) -> Self? {
        let source = text as NSString
        guard extent.location >= 0, extent.length == source.length, focus.location >= 0, focus.length > 0,
              focus.length <= Int.max - focus.location, extent.length <= Int.max - extent.location else { return nil }
        let start = max(extent.location, focus.location), end = min(extent.upperBound, focus.upperBound)
        guard end > start else { return nil }
        let local = NSRange(location: start - extent.location, length: end - start)
        guard source.rangeOfComposedCharacterSequence(at: local.location).location == local.location,
              NSMaxRange(local) == source.length || source.rangeOfComposedCharacterSequence(at: NSMaxRange(local)).location == NSMaxRange(local) else { return nil }
        return .init(before: source.substring(to: local.location), match: source.substring(with: local),
            after: source.substring(from: NSMaxRange(local)), omittedBefore: omittedBefore, omittedAfter: omittedAfter,
            partialStart: focus.location < extent.location, partialEnd: focus.upperBound > extent.upperBound)
    }
}
struct WorkspaceSearchResultRow: Identifiable {
    struct ID: Hashable { let resultID: String; let focus: WorkspaceSearchResultFocus }
    let result: LibrarySearchResult
    let focus: WorkspaceSearchResultFocus
    let parts: WorkspaceSearchContextParts?
    var id: ID { .init(resultID: result.id, focus: focus) }
    var isSummary: Bool { focus == .summary }
    var field: SearchField? { if case .external(let field, _, _) = focus { field } else { nil } }
}
struct WorkspaceSearchResultSection: Identifiable {
    let id: String
    let title: String?
    var rows: [WorkspaceSearchResultRow]
}

/// Presentation owns order/selection; the immutable search report remains the
/// source of resource identities, exact hit coordinates and opening evidence.
@MainActor @Observable final class WorkspaceSearchResultsController {
    var layout = WorkspaceSearchResultLayout.context
    var grouping = WorkspaceSearchResultGrouping.resource { didSet { rebuild() } }
    var order = WorkspaceSearchResultOrder.source { didSet { rebuild() } }
    var selectedID: WorkspaceSearchResultRow.ID?
    private(set) var revision = 0
    private(set) var sections: [WorkspaceSearchResultSection] = []
    private(set) var rows: [WorkspaceSearchResultRow] = []
    @ObservationIgnored private var results: [LibrarySearchResult] = []
    @ObservationIgnored private var indexes: [WorkspaceSearchResultRow.ID: Int] = [:]
    var selectedIndex: Int? { selectedID.flatMap { indexes[$0] } }
    var selected: WorkspaceSearchResultRow? { selectedIndex.map { rows[$0] } }
    var canNext: Bool { !rows.isEmpty && (selectedIndex ?? -1) < rows.count - 1 }
    var canPrevious: Bool { !rows.isEmpty && (selectedIndex ?? rows.count) > 0 }
    func setResults(_ value: [LibrarySearchResult], preserveSelection: Bool = false) {
        results = value; if !preserveSelection { selectedID = nil }; rebuild()
    }
    func next() { move(1) }
    func previous() { move(-1) }
    private func move(_ delta: Int) {
        guard !rows.isEmpty else { selectedID = nil; return }
        let start = selectedIndex ?? (delta > 0 ? -1 : rows.count)
        let index = min(rows.count - 1, max(0, start + delta))
        selectedID = rows[index].id
    }
    private func rebuild() {
        let selected = selectedID
        let ordered: [LibrarySearchResult]
        if order == .source { ordered = results }
        else {
            let mode = order
            ordered = results.enumerated().sorted { lhs, rhs in
                let a = lhs.element, b = rhs.element
                if mode == .mostHits, a.hitCount != b.hitCount { return a.hitCount > b.hitCount }
                if a.resourceTitle != b.resourceTitle {
                    let comparison = a.resourceTitle.compare(b.resourceTitle, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: Locale(identifier: "en_US_POSIX"))
                    if comparison != .orderedSame { return mode == .titleDescending ? comparison == .orderedDescending : comparison == .orderedAscending }
                }
                if a.resourceID != b.resourceID { return a.resourceID < b.resourceID }
                if a.sectionOrdinal != b.sectionOrdinal { return a.sectionOrdinal < b.sectionOrdinal }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
        var sections: [WorkspaceSearchResultSection] = [], byResource: [String: Int] = [:]
        for result in ordered {
            let resultRows = Self.makeRows(result)
            let key = grouping == .resource ? result.resourceID : "all"
            if let index = byResource[key] { sections[index].rows += resultRows }
            else { byResource[key] = sections.count; sections.append(.init(id: key, title: grouping == .resource ? result.resourceTitle : nil, rows: resultRows)) }
        }
        self.sections = sections; rows = sections.flatMap(\.rows)
        revision += 1
        indexes = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        selectedID = selected.flatMap { indexes[$0] != nil ? $0 : nil } ?? rows.first?.id
    }
    private static func makeRows(_ result: LibrarySearchResult) -> [WorkspaceSearchResultRow] {
        var rows: [WorkspaceSearchResultRow] = []
        let contexts = Dictionary(result.contexts.map { ($0.range, $0.snippet) }, uniquingKeysWith: { first, _ in first })
        for hit in result.hits {
            let snippet = contexts[hit.range] ?? result.snippet
            let parts = WorkspaceSearchContextParts.make(text: snippet.text, extent: snippet.rangeInArticle, focus: hit.range,
                omittedBefore: snippet.omittedPrefix, omittedAfter: snippet.omittedSuffix)
            rows.append(.init(result: result, focus: .reader(hit.range), parts: parts))
        }
        for hit in result.externalHits {
            let parts = WorkspaceSearchContextParts.make(text: hit.value, extent: .init(location: 0, length: hit.value.utf16.count), focus: hit.range, omittedBefore: false, omittedAfter: false)
            rows.append(.init(result: result, focus: .external(hit.field, hit.valueIndex, hit.range), parts: parts))
        }
        if rows.isEmpty { rows.append(.init(result: result, focus: .summary, parts: nil)) }
        return rows
    }
}
