import Foundation
import LibronixCore

enum WorkspaceSearchExportError: Error, LocalizedError, Equatable {
    case unavailable, tooLarge, sourceDestination
    var errorDescription: String? {
        switch self {
        case .unavailable: "Los resultados cambiaron. Ejecuta la búsqueda de nuevo antes de exportar."
        case .tooLarge: "La exportación supera el límite de tamaño. Reduce el ámbito de búsqueda."
        case .sourceDestination: "Elige otro destino. La exportación no puede sustituir un recurso de la biblioteca."
        }
    }
}

/// A frozen presentation snapshot: exported rows retain the order and exact
/// occurrence identities shown in the result browser, including metadata hits.
struct WorkspaceSearchExport: Sendable {
    let rows: [WorkspaceSearchResultRow]
    let query: String
    let report: LibrarySearchReport
    let complete: Bool
    private let stamps: [LibrarySearchFileStamp]

    init(rows: [WorkspaceSearchResultRow], query: String, report: LibrarySearchReport, complete: Bool) throws {
        let originals = Dictionary(report.results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard rows.allSatisfy({ originals[$0.result.id] == $0.result && $0.focus.isValid(for: $0.result) }),
              Set(rows.map(\.id)).count == rows.count else { throw WorkspaceSearchExportError.unavailable }
        self.rows = rows; self.query = query; self.report = report
        self.complete = complete && report.coverageComplete && report.runState == .finished
        self.stamps = Array(Set(report.results.flatMap(\.sourceStamps)))
    }

    func csv(maximumBytes: Int = 64 * 1024 * 1024) throws -> String {
        try Task.checkCancellation(); try LibrarySearchFileStamp.verify(stamps)
        var output = CSVOutput.row(["query", "resource", "resource_id", "reference", "article", "section_ordinal",
            "row_kind", "field", "field_value_index", "offset_utf16", "length_utf16", "before", "match", "after",
            "context_available", "prefix_omitted", "suffix_omitted", "partial_match_start", "partial_match_end",
            "result_observed_hits", "source_text_sha256", "search_complete", "context_complete", "run_state", "scope"])
        var bytes = output.utf8.count
        guard maximumBytes >= bytes else { throw WorkspaceSearchExportError.tooLarge }
        for row in rows {
            try Task.checkCancellation()
            let kind: String, field: String, valueIndex: String, location: String, length: String
            switch row.focus {
            case .reader(let range):
                kind = "reader"; field = ""; valueIndex = ""; location = String(range.location); length = String(range.length)
            case .external(let namedField, let index, let range):
                kind = "metadata"; field = namedField.rawValue; valueIndex = String(index)
                location = String(range.location); length = String(range.length)
            case .summary:
                kind = "summary"; field = ""; valueIndex = ""; location = ""; length = ""
            case .automatic: throw WorkspaceSearchExportError.unavailable
            }
            func flag(_ value: Bool?) -> String { value.map(String.init) ?? "" }
            let result = row.result, parts = row.parts
            let line = CSVOutput.row([query, result.resourceTitle, result.resourceID, result.bibleReference ?? "",
                result.articleTitle, String(result.sectionOrdinal), kind, field, valueIndex, location, length,
                parts?.before ?? "", parts?.match ?? "", parts?.after ?? "", String(parts != nil),
                flag(parts?.omittedBefore), flag(parts?.omittedAfter), flag(parts?.partialStart), flag(parts?.partialEnd),
                String(result.hitCount), result.decodedTextSHA256, String(complete), String(report.contextCoverageComplete),
                report.runState.rawValue, report.scopeDescription])
            let lengthInBytes = line.utf8.count
            guard lengthInBytes <= maximumBytes - bytes else { throw WorkspaceSearchExportError.tooLarge }
            output += line; bytes += lengthInBytes
        }
        try LibrarySearchFileStamp.verify(stamps)
        return output
    }

    func write(to url: URL) throws {
        let destination = url.resolvingSymlinksInPath().standardizedFileURL
        guard !stamps.contains(where: { $0.url.resolvingSymlinksInPath().standardizedFileURL == destination }) else {
            throw WorkspaceSearchExportError.sourceDestination
        }
        let data = Data(try csv().utf8)
        try Task.checkCancellation(); try LibrarySearchFileStamp.verify(stamps)
        try data.write(to: url, options: .atomic)
    }
}

@MainActor extension WorkspaceSearchController {
    var canExportResults: Bool { canOpenResults && !isSearching && !presentation.rows.isEmpty }
    func exportSnapshot() throws -> WorkspaceSearchExport {
        guard canExportResults, let report, let submittedQuery else { throw WorkspaceSearchExportError.unavailable }
        return try .init(rows: presentation.rows, query: submittedQuery, report: report, complete: coverageComplete)
    }
}
