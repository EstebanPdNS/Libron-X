import Foundation
import LibronixCore

/// Per-resource format census. This never exports book text or claims rendering
/// acceptance from a successful container/style-table inspection.
enum ResourceFormatInspection {
    static func run(_ path: String, files: Set<String> = [], allArticles: Bool = false) async throws -> Data {
        let imported = try await LibraryImporter().importDirectory(at: URL(fileURLWithPath: path))
        let resources = imported.resources.filter { files.isEmpty || files.contains($0.fileName) }
        guard files.isSubset(of: Set(resources.map(\.fileName))) else { throw LibronixBookError.entryNotFound }
        let books = LibronixBookService()
        var records: [[String: Any]] = []
        for resource in resources {
            try Task.checkCancellation()
            var record: [String: Any] = ["file": resource.fileName, "format": resource.format.rawValue,
                "title": resource.title, "metadataSource": resource.provenance.rawValue,
                "fullRenderingParity": false]
            let before = try LegacyGraphicsService.fileStamp(resource.location)
            do {
                let source: LibraryResource
                if resource.format == .libronixLLS { source = try await books.prepare(resource) }
                else if resource.format == .legacyLSF { source = resource }
                else { throw LibronixBookError.unsupportedArchive }
                let styles = try LegacyTypographyReader.inspect(lsfURL: source.location)
                record["characterStyles"] = styles.characterStyles.count
                record["paragraphStyles"] = styles.paragraphStyles.count
                record["fontGroups"] = styles.fontGroups.map { ["name": $0.name, "family": $0.family] }
                record["fontFamilies"] = Array(Set(styles.characterStyles.map { styles.family(for: $0.font) })).sorted()
                let reader = LegacyContentService()
                let index = try await reader.inspect(source.location)
                record["totalArticles"] = index.sections.count
                let ordinals = allArticles ? Array(index.sections.indices)
                    : Set(Array(0..<min(4, index.sections.count)) + [index.sections.count / 2, max(0, index.sections.count - 1)]).sorted()
                var decoded = 0, failures: [[String: Any]] = [], tables = 0, labels = 0, extendedRuns = 0
                var failureCount = 0, graphics = 0, referenceRuns = 0
                var interlinearUnits = 0, interlinearLines = 0, mappingRecords = 0
                var unresolvedCharacters = Set<UInt16>(), unresolvedParagraphs = Set<UInt32>()
                func paragraph(_ value: LegacyParagraph) {
                    if styles.paragraphStyle(value.styleIdentifier) == nil { unresolvedParagraphs.insert(value.styleIdentifier) }
                    if value.label != nil { labels += 1 }
                    for child in value.children { paragraph(child) }
                    if let table = value.table {
                        tables += 1
                        for row in table.rows { for cell in row.cells { paragraph(cell.content) } }
                    }
                }
                func textRuns(_ values: [LegacyTextRun]) {
                    for run in values {
                        if styles.characterStyle(run.styleIdentifier) == nil { unresolvedCharacters.insert(run.styleIdentifier) }
                        if run.extendedAttributes != nil { extendedRuns += 1 }
                    }
                }
                func interlinear(_ unit: LegacyInterlinearRun) {
                    interlinearUnits += 1; interlinearLines += unit.lines.count
                    for line in unit.lines {
                        mappingRecords += line.mappings.count
                        // The surface runs already occur in the article run
                        // projection. Annotation runs have their own coordinates.
                        if line.ordinal != 0 { textRuns(line.runs) }
                        line.interlinears.forEach(interlinear)
                    }
                }
                for ordinal in ordinals where index.sections.indices.contains(ordinal) {
                    do {
                        let content = try await reader.read(source.location, ordinal: ordinal)
                        decoded += 1; content.paragraphs.forEach(paragraph)
                        graphics += content.graphics.count; referenceRuns += content.anchors.filter { $0.sourceToken == 0x52 }.count
                        textRuns(content.runs); (content.interlinears ?? []).forEach(interlinear)
                    } catch {
                        if error is CancellationError { throw error }
                        failureCount += 1
                        guard failures.count < 500 else { continue }
                        var failure: [String: Any] = ["ordinal": ordinal, "error": error.localizedDescription]
                        if case let LegacyContentError.unsupportedRunStructure(offset) = error,
                           let payload = try? LegacyContentReader.decodedSectionPayload(lsfURL: source.location, ordinal: ordinal),
                           offset >= index.sections[ordinal].payloadOffset {
                            let at = Int(offset - index.sections[ordinal].payloadOffset)
                            if at + 2 <= payload.count { failure["wordAtFailure"] = Int(payload[at]) | Int(payload[at + 1]) << 8 }
                            failure["decodedOffset"] = at
                            failure["decodedHeaderHex"] = payload.prefix(20).map { String(format: "%02x", $0) }.joined()
                        }
                        failures.append(failure)
                    }
                }
                record["allArticlesInspected"] = allArticles
                if !allArticles { record["sampledOrdinals"] = ordinals }
                record["inspectedArticles"] = ordinals.count; record["decodedSamples"] = decoded
                record["failureCount"] = failureCount
                record["sampleFailures"] = failures; record["sampledTables"] = tables
                record["sampledLabels"] = labels; record["sampledExtendedRuns"] = extendedRuns
                record["sampledGraphics"] = graphics; record["sampledReference52Runs"] = referenceRuns
                record["interlinearUnits"] = interlinearUnits; record["interlinearLines"] = interlinearLines
                record["interlinearMappingRecords"] = mappingRecords
                record["unresolvedCharacterStyles"] = unresolvedCharacters.sorted()
                record["unresolvedParagraphStyles"] = unresolvedParagraphs.sorted()
                record["status"] = failureCount == 0 ? (allArticles ? "all-content-and-styles-readable" : "sampled-content-and-styles-readable") : "partial-content"
            } catch { record["status"] = "pending"; record["error"] = error.localizedDescription }
            guard try LegacyGraphicsService.fileStamp(resource.location) == before else { throw LibronixBookError.sourceChanged }
            record["sourceStampPreserved"] = true; records.append(record)
            FileHandle.standardError.write(Data("Format audit \(records.count)/\(resources.count): \(resource.fileName) — \(record["status"]!)\n".utf8))
        }
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "resources": records,
            "resourceCount": records.count, "allOriginalStampsPreserved": true,
            "scope": allArticles ? "All physical articles and style tables in each selected resource; no full rendering parity claim"
                : "All resource style tables where supported, up to six decoded articles per resource; no full rendering parity claim"],
            options: [.prettyPrinted, .sortedKeys])
    }
}
