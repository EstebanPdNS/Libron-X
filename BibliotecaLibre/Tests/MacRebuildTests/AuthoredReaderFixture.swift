import Foundation
import LibronixCore

// Reuses only the authored binary test-data generator, not prototype application code.
struct AuthoredReaderFixture {
    let root: URL
    let resources: [LibraryResource]

    init(documents: [[String?]]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("libronx-ui-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values: [LibraryResource] = []
        for (index, sections) in documents.enumerated() {
            var tart = Data()
            for text in sections {
                var payload = Self.article(text ?? "Unsupported synthetic article")
                if text == nil { payload[20] = 2 }
                tart.append(Self.le16(0) + Self.le32(UInt32(payload.count)) + payload)
            }
            let data = Self.container(tart)
            let url = root.appendingPathComponent("synthetic-\(index + 1).LSF")
            try data.write(to: url)
            values.append(LibraryResource(location: url, title: "Synthetic \(index + 1)", byteCount: Int64(data.count),
                format: .legacyLSF, support: .metadataOnly, provenance: .fileName))
        }
        resources = values
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private static func article(_ text: String) -> Data {
        let units = Array(text.utf16)
        var payload = Data(repeating: 0, count: 36)
        put16(17, in: &payload, at: 4)
        put32(1, in: &payload, at: 6)
        put16(1, in: &payload, at: 10)
        put16(1, in: &payload, at: 12)
        put32(UInt32(units.count), in: &payload, at: 16)
        put16(1, in: &payload, at: 20)
        put16(1, in: &payload, at: 22)
        put16(1, in: &payload, at: 24)
        put32(10_000, in: &payload, at: 26)
        put32(UInt32(units.count + 1), in: &payload, at: 32)
        payload.append(le16(17) + le16(0) + le16(0) + le16(UInt16(units.count)) + le16(1033) + Data([0xf0]))
        for unit in units { payload.append(le16(unit)) }
        payload.append(le16(0))
        put32(UInt32(payload.count), in: &payload, at: 0)
        return payload
    }

    private static func container(_ tart: Data) -> Data {
        var data = Data(repeating: 0, count: 88)
        data.replaceSubrange(0..<4, with: Data("LSFF".utf8))
        data.replaceSubrange(8..<12, with: Data("GTTL".utf8))
        data.replaceSubrange(36..<40, with: Data("pcr ".utf8))
        put32(36, in: &data, at: 40)
        data.replaceSubrange(44..<48, with: Data("LSFF".utf8))
        data.replaceSubrange(48..<52, with: Data("GTTL".utf8))
        data.replaceSubrange(62..<66, with: Data("tart".utf8))
        put32(UInt32(tart.count), in: &data, at: 70)
        put32(88, in: &data, at: 74)
        data.replaceSubrange(80..<84, with: Data("tart".utf8))
        put32(UInt32(tart.count), in: &data, at: 84)
        data.append(tart)
        put32(UInt32(data.count - 8), in: &data, at: 4)
        return data
    }
    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 255), UInt8(value >> 8)]) }
    private static func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> (8 * $0)) & 255) }) }
    private static func put16(_ value: UInt16, in data: inout Data, at offset: Int) { data.replaceSubrange(offset..<(offset + 2), with: le16(value)) }
    private static func put32(_ value: UInt32, in data: inout Data, at offset: Int) { data.replaceSubrange(offset..<(offset + 4), with: le32(value)) }
}
