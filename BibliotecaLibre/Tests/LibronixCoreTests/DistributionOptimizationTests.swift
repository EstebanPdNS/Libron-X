import Foundation
import Testing
@testable import LibronixCore

struct DistributionOptimizationTests {
    @Test func optimizedCorpusKeepsNativeReaderRecordsAndReferenceNavigation() throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_DISTRIBUTION_OVERLAYS"] else {
            return // The private corpus is intentionally absent from source distributions.
        }
        struct Receipt: Decodable {
            let source: String
            let originalBytes: Int
            let optimizedBytes: Int
            let verifiedRecords: Int
            let sourceUnchanged: Bool
        }
        let root = URL(fileURLWithPath: path)
        let receipts = try JSONDecoder().decode([Receipt].self, from: Data(contentsOf: root.appendingPathComponent("recompression-validation.json")))
        #expect(!receipts.isEmpty)
        for receipt in receipts where receipt.optimizedBytes < receipt.originalBytes {
            let source = URL(fileURLWithPath: receipt.source)
            let optimized = root.appendingPathComponent(source.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)
                .appendingPathComponent("normalized/reader.sqlite")
            let before = try LibronNativeDatabase(source), after = try LibronNativeDatabase(optimized)
            #expect(receipt.sourceUnchanged && receipt.verifiedRecords > 0)
            for key in ["header", "typography", "dictionary", "commentary-index", "section/0", "section/1", "section/2"] {
                #expect(try before.get(key) == after.get(key), "Changed native record: \(source.lastPathComponent) / \(key)")
            }
            let references = try before.referenceEntries()
            #expect(try after.referenceEntries().map { "\($0.reference)|\($0.ordinal)|\($0.offset)" } == references.map { "\($0.reference)|\($0.ordinal)|\($0.offset)" })
            for reference in [references.first?.reference, references.last?.reference].compactMap({ $0 }) {
                let old = try before.resolve(reference), new = try after.resolve(reference)
                #expect(old?.ordinal == new?.ordinal && old?.offset == new?.offset && old?.reference == new?.reference)
            }
        }
    }
}
