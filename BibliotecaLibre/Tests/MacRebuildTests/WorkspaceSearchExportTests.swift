import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct WorkspaceSearchExportTests {
    private func settle(_ controller: WorkspaceSearchController) async throws {
        for _ in 0..<2000 { if !controller.isSearching { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Search export fixture did not finish")
    }
    /// Independent RFC 4180 reader for round-trip assertions; quoted source
    /// commas, quotes and CR/LF must never create extra columns or records.
    private func decode(_ input: String) -> [[String]] {
        let text = Array(input.unicodeScalars)
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false, index = 0
        while index < text.count {
            let value = text[index]
            if value == "\"" {
                if quoted && index + 1 < text.count && text[index + 1] == "\"" { cell.unicodeScalars.append(value); index += 1 }
                else { quoted.toggle() }
            } else if !quoted && value == "," { row.append(cell); cell = "" }
            else if !quoted && value == "\r" && index + 1 < text.count && text[index + 1] == "\n" {
                row.append(cell); rows.append(row); row = []; cell = ""; index += 1
            } else { cell.unicodeScalars.append(value) }
            index += 1
        }
        return rows
    }
    @Test func exportsEveryVisibleOccurrenceInItsChosenOrderWithExactUnicodeCoordinates() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["😀 before needle, \"quoted\"\r\nneedle"], ["needle after"]]); defer { fixture.remove() }
        let controller = WorkspaceSearchController(); controller.query = "needle"; controller.allResources = true
        controller.run(fixture.resources); try await settle(controller)
        #expect(controller.canExportResults && controller.coverageComplete)
        controller.presentation.order = .titleDescending; controller.presentation.grouping = .none
        let before = try fixture.resources.map { try Data(contentsOf: $0.location) }
        let snapshot = try controller.exportSnapshot(), rows = decode(try snapshot.csv())
        #expect(rows.count == controller.presentation.rows.count + 1 && rows.count == 4)
        #expect(rows.allSatisfy { $0.count == 25 })
        for (index, source) in controller.presentation.rows.enumerated() {
            let exported = rows[index + 1]
            #expect(exported[2] == source.result.resourceID && exported[5] == String(source.result.sectionOrdinal))
            if case .reader(let range) = source.focus {
                #expect(exported[9] == String(range.location) && exported[10] == String(range.length))
            }
            #expect(exported[12] == "needle" && exported[21] == "true" && exported[23] == "finished")
        }
        let target = fixture.root.appendingPathComponent("export.csv"); try snapshot.write(to: target)
        #expect(decode(try String(contentsOf: target, encoding: .utf8)) == rows)
        #expect(throws: WorkspaceSearchExportError.sourceDestination) { try snapshot.write(to: fixture.resources[0].location) }
        let alias = fixture.root.appendingPathComponent("source-alias.csv")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.resources[0].location)
        #expect(throws: WorkspaceSearchExportError.sourceDestination) { try snapshot.write(to: alias) }
        #expect(try fixture.resources.enumerated().allSatisfy { try Data(contentsOf: $0.element.location) == before[$0.offset] })
        controller.query = "different"
        #expect(!controller.canExportResults)
        #expect(throws: WorkspaceSearchExportError.self) { try controller.exportSnapshot() }
        var data = before[0]; data.append(0); try data.write(to: fixture.resources[0].location)
        #expect(throws: (any Error).self) { try snapshot.write(to: target) }
        #expect(decode(try String(contentsOf: target, encoding: .utf8)) == rows)
    }
    @Test func partialReportsAndMissingContextsRemainExplicitAndBounded() async throws {
        let text = "needle " + String(repeating: "context ", count: 100) + "needle"
        let fixture = try AuthoredReaderFixture(documents: [[text, text]]); defer { fixture.remove() }
        let report = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: fixture.resources,
            query: SearchQueryParser.parse("needle"), budget: .init(maximumResults: 1, snippetUTF16: 8, maximumContextUTF16: 8))
        let presentation = WorkspaceSearchResultsController(); presentation.setResults(report.results)
        let snapshot = try WorkspaceSearchExport(rows: presentation.rows, query: "needle", report: report, complete: true)
        let rows = decode(try snapshot.csv())
        #expect(rows.dropFirst().allSatisfy { $0[21] == "false" && $0[22] == "false" })
        #expect(rows.contains { $0[14] == "false" && $0[12].isEmpty })
        #expect(throws: WorkspaceSearchExportError.self) { try snapshot.csv(maximumBytes: 1) }
        #expect(throws: WorkspaceSearchExportError.self) {
            try WorkspaceSearchExport(rows: presentation.rows + presentation.rows, query: "needle", report: report, complete: false)
        }
    }
    @Test func metadataOccurrencesKeepTheirOwnFieldAndValueCoordinates() async throws {
        let fixture = try AuthoredOEBFixture(chapterBody: "<span id='a1'></span><p>needle body</p><span id='a2'></span><p>other</p>"); defer { fixture.remove() }
        let report = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [fixture.resource], query: SearchQueryParser.parse("title:Chapter OR body:needle"))
        let presentation = WorkspaceSearchResultsController(); presentation.setResults(report.results)
        let rows = decode(try WorkspaceSearchExport(rows: presentation.rows, query: "title:Chapter OR body:needle", report: report, complete: true).csv())
        let metadata = try #require(rows.first { $0[6] == "metadata" })
        #expect(metadata[7] == "title" && metadata[8] == "0" && metadata[12] == "Chapter")
        #expect(rows.contains { $0[6] == "reader" && $0[12] == "needle" })
    }
}
