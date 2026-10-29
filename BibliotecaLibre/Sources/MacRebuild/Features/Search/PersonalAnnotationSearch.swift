import Foundation
import LibronixCore

struct PersonalAnnotationSearchFilter: Sendable, Equatable {
    var documentID: UUID?
    var resourceID: String?
    var color: String?
    var includeNotes = true
    var includeHighlights = true
}

enum PersonalAnnotationDestination: Sendable {
    case note(BibleReferencePersonalDestination)
    case highlight(ReaderHighlight, LibraryResource, [LibrarySearchFileStamp], SearchTextRange)
}
struct PersonalAnnotationResult: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let snippet: String
    let snippetMatch: SearchTextRange
    let destination: PersonalAnnotationDestination
}
struct PersonalAnnotationReport: Sendable {
    var results: [PersonalAnnotationResult] = []
    var warnings: [String] = []
    var complete = true
}

/// Search snapshots without changing the documents or recreating highlight text.
/// Source offsets refer to the unchanged editor/reader projection in UTF-16.
actor PersonalAnnotationSearch {
    private let provider: any LibrarySearchContentProvider
    init(provider: any LibrarySearchContentProvider = WorkspaceSearchReader()) { self.provider = provider }

    func search(query: String, documents: [StudyDocument], highlights: [ReaderHighlight],
                resources: [LibraryResource], filter: PersonalAnnotationSearchFilter,
                maximumResults: Int = 500) async throws -> PersonalAnnotationReport {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, needle.utf16.count <= 512, (1...10_000).contains(maximumResults) else {
            throw PersonalStateError.invalid("Introduce un texto de búsqueda válido.")
        }
        guard Set(resources.map(\.id)).count == resources.count else { throw LibrarySearchError.duplicateResourceID("annotation search") }
        var report = PersonalAnnotationReport()
        func matches(_ text: String) throws -> [NSRange] {
            let source = text as NSString
            var cursor = 0, found: [NSRange] = []
            while cursor < source.length {
                try Task.checkCancellation()
                let hit = source.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                       range: NSRange(location: cursor, length: source.length - cursor))
                guard hit.location != NSNotFound, hit.length > 0 else { break }
                if Range(hit, in: text) != nil { found.append(hit) }
                cursor = NSMaxRange(hit)
                if found.count > maximumResults { break }
            }
            return found
        }
        func excerpt(_ text: String, hit: NSRange) -> (text: String, match: SearchTextRange) {
            let source = text as NSString
            let from = max(0, hit.location - 60), to = min(source.length, NSMaxRange(hit) + 100)
            let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: from, length: to - from))
            let prefix = range.location > 0 ? "…" : ""
            let body = source.substring(with: range).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            return (prefix + body + (NSMaxRange(range) < source.length ? "…" : ""),
                    .init(location: prefix.utf16.count + hit.location - range.location, length: hit.length))
        }
        func append(_ result: PersonalAnnotationResult) -> Bool {
            if report.results.count >= maximumResults {
                report.complete = false; report.warnings.append("Se alcanzó el límite de búsqueda"); return false
            }
            report.results.append(result); return true
        }
        if filter.includeNotes && filter.color == nil {
            for document in documents where document.kind.usesNotes && (filter.documentID == nil || filter.documentID == document.id) {
                try Task.checkCancellation()
                let source = try PersonalReferenceProjection.source(document)
                if !source.projectionComplete { report.complete = false; report.warnings += source.warnings }
                let notes = Dictionary(uniqueKeysWithValues: document.notes.map { ($0.id, $0) })
                for field in source.fields where field.kind == .noteTitle || field.kind == .noteBody {
                    guard let id = field.entryID, let note = notes[id] else { continue }
                    if let resourceID = filter.resourceID, note.effectiveAnchor.location?.resourceID != resourceID {
                        if note.effectiveAnchor.location == nil && [.legacyReference, .legacySelection].contains(note.effectiveAnchor.kind) {
                            report.complete = false
                            report.warnings.append(document.title + ": " + "Algunas notas antiguas no tienen un recurso verificado.")
                        }
                        continue
                    }
                    let fingerprint = try field.projectionFingerprint()
                    for hit in try matches(field.text) {
                        let destination = BibleReferencePersonalDestination(documentID: document.id, entryID: id, field: field.kind,
                            textSHA256: LibrarySearchService.textFingerprint(field.text), projectionSHA256: fingerprint,
                            range: .init(location: hit.location, length: hit.length))
                        let snippet = excerpt(field.text, hit: hit)
                        guard append(.init(title: document.title + " · " + note.title, snippet: snippet.text, snippetMatch: snippet.match, destination: .note(destination))) else { return report }
                    }
                }
            }
        }
        // Highlights have no notebook association; a notebook filter excludes them.
        if filter.includeHighlights && filter.documentID == nil {
            let selected = highlights.filter { (filter.resourceID == nil || $0.resourceID == filter.resourceID) && (filter.color == nil || $0.color == filter.color) }
            let grouped = Dictionary(grouping: selected, by: \.resourceID)
            for resourceID in grouped.keys.sorted() {
                try Task.checkCancellation()
                guard let resource = resources.first(where: { $0.id == resourceID }) else {
                    report.complete = false; report.warnings.append("Recurso no disponible: " + resourceID); continue
                }
                let marks = grouped[resourceID] ?? []
                do {
                    guard await provider.supports(resource) else { throw ReaderOutputError.unsupportedFormat }
                    let prepared = try await provider.prepare(resource)
                    if !prepared.warnings.isEmpty { report.complete = false; report.warnings += prepared.warnings }
                    try prepared.validateDirectory()
                    var resourceResults: [PersonalAnnotationResult] = []
                    for (ordinal, group) in Dictionary(grouping: marks, by: \.ordinal).sorted(by: { $0.key < $1.key }) {
                        try Task.checkCancellation()
                        guard let article = prepared.article(at: ordinal) else { report.complete = false; report.warnings.append(resource.title + ": " + "Sección no disponible"); continue }
                        let decoded = try await provider.read(resource, article: article, prepared: prepared)
                        if !decoded.warnings.isEmpty { report.complete = false; report.warnings += decoded.warnings }
                        let text = decoded.text, fingerprint = LibrarySearchService.textFingerprint(text), source = text as NSString
                        for mark in group {
                            guard mark.fingerprint == fingerprint, mark.range.location >= 0, mark.range.length > 0,
                                  mark.range.location <= source.length, mark.range.length <= source.length - mark.range.location,
                                  Range(mark.range, in: text) != nil else {
                                report.complete = false; report.warnings.append(resource.title + ": " + "Resaltado no verificable"); continue
                            }
                            let marked = source.substring(with: mark.range)
                            for hit in try matches(marked) {
                                let absolute = SearchTextRange(location: mark.range.location + hit.location, length: hit.length)
                                let snippet = excerpt(text, hit: absolute.nsRange)
                                resourceResults.append(.init(title: resource.title, snippet: snippet.text, snippetMatch: snippet.match,
                                    destination: .highlight(mark, resource, prepared.sourceStamps, absolute)))
                                if resourceResults.count > maximumResults { break }
                            }
                            if resourceResults.count > maximumResults { break }
                        }
                        if resourceResults.count > maximumResults { break }
                    }
                    try await provider.verifyUnchanged(resource, prepared: prepared)
                    for result in resourceResults { guard append(result) else { return report } }
                } catch is CancellationError { throw CancellationError() }
                catch { report.complete = false; report.warnings.append(resource.title + ": " + error.localizedDescription) }
            }
        }
        report.warnings = Array(Set(report.warnings)).sorted()
        return report
    }
}
