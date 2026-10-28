import Foundation
import LibronixCore

// Authored binary fixture for checked original positions.
struct OriginalFavoriteFixture {
    let root: URL
    let resources: [LibraryResource]
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("libronx-links-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let refs = ["Jn 1:1", "Jn 3:16", "Ge 1:1", "Ps 23:1"], labels = ["John1", "John3", "Genesis1", "Psalm23"]
        var resources: [LibraryResource] = []
        for edition in ["A", "B"] {
            let identifier = Data([1,0,0,0,edition == "A" ? 3 : 4,0,0,0,53,0]), url = root.appendingPathComponent(edition + ".LSF")
            let lix = root.appendingPathComponent(edition + ".LIX")
            var tart = Data(), hits = Data(), titles = Data(), counts = Data(), cumulative: UInt32 = 0
            for i in refs.indices {
                let offset = tart.count, text = "Edition \(edition) · \(labels[i])", units = Array(text.utf16)
                var doc = Data(repeating: 0, count: 36)
                Self.put16(17, &doc, 4); Self.put32(1, &doc, 6); Self.put16(1, &doc, 10); Self.put16(1, &doc, 12)
                Self.put32(UInt32(units.count), &doc, 16); Self.put16(1, &doc, 20); Self.put16(1, &doc, 22); Self.put16(2, &doc, 24)
                Self.put32(10_000, &doc, 26); Self.put32(UInt32(units.count + 1), &doc, 32)
                doc.append(Self.le16(81) + Self.le16(128) + Self.le16(2) + Self.le16(UInt16(refs[i].utf8.count)) + Data(refs[i].utf8))
                doc.append(Self.le16(17) + Self.le16(0) + Self.le16(0) + Self.le16(UInt16(units.count)) + Self.le16(1033) + Data([0xf0]))
                for unit in units { doc.append(Self.le16(unit)) }; doc.append(Self.le16(0)); Self.put32(UInt32(doc.count), &doc, 0)
                tart.append(Self.le16(0) + Self.le32(UInt32(doc.count)) + doc)
                cumulative += UInt32(units.count); counts.append(Self.le32(cumulative))
                hits.append(Self.le32(UInt32(i)) + Self.le32(UInt32(offset)) + Self.le32(UInt32(titles.count)) + Self.le32(0x80000000) + Self.le32(UInt32(i)) + Data([1]))
                let title = Array("Own article \(i)".utf16); titles.append(Self.le16(UInt16(title.count)))
                for unit in title { titles.append(Self.le16(unit)) }; titles.append(Self.le16(0))
            }
            let lsfData = Self.container("GTTL", chunks: [.init("bkid", identifier), .init("tart", tart)])
            try lsfData.write(to: url)
            let aidx = Chunk("AIDX", children: [.init("info", Self.le16(0) + Self.le32(4) + Self.le32(4) + Self.le16(1)), .init("klst", titles), .init("hlst", hits)])
            try Self.container("BIDX", chunks: [.init("bkid", Self.le16(1) + identifier), aidx, .init("ccct", counts)]).write(to: lix)
            resources.append(LibraryResource(location: url, indexLocation: lix, title: "Edition \(edition)", byteCount: Int64(lsfData.count),
                format: .legacyLSF, support: .metadataOnly, provenance: .fileName, legacyIdentifier: identifier.map { String(format:"%02x",$0) }.joined()))
        }
        self.resources = resources
    }
    func remove() {
        for resource in resources { UserDefaults.standard.removeObject(forKey: "readerPosition.v1." + resource.id) }
        try? FileManager.default.removeItem(at: root)
    }
    private struct Chunk {
        let tag: String; let data: Data; let children: [Chunk]
        init(_ tag: String, _ data: Data = Data(), children: [Chunk] = []) { self.tag = tag; self.data = data; self.children = children }
        var payloadSize: Int { children.isEmpty ? data.count : children.reduce(0) { $0 + 8 + $1.payloadSize } }
        var entryCount: Int { 1 + children.reduce(0) { $0 + $1.entryCount } }
    }
    private static func container(_ kind: String, chunks: [Chunk]) -> Data {
        let size = 18 + chunks.reduce(0) { $0 + $1.entryCount } * 18
        var header = Data(repeating: 0, count: 44), directory = Data(repeating: 0, count: 18), payload = Data()
        header.replaceSubrange(0..<4, with: Data("LSFF".utf8)); header.replaceSubrange(8..<12, with: Data(kind.utf8))
        header.replaceSubrange(36..<40, with: Data("pcr ".utf8)); put32(UInt32(size), &header, 40)
        directory.replaceSubrange(0..<4, with: Data("LSFF".utf8)); directory.replaceSubrange(4..<8, with: Data(kind.utf8))
        func emit(_ chunk: Chunk, at offset: Int) -> Data {
            directory.append(Data(chunk.tag.utf8) + le32(0) + le32(UInt32(chunk.payloadSize)) + le32(UInt32(offset + 8)) + le16(UInt16(chunk.children.count)))
            var bytes = Data(chunk.tag.utf8) + le32(UInt32(chunk.payloadSize))
            if chunk.children.isEmpty { bytes.append(chunk.data) }
            else { for child in chunk.children { bytes.append(emit(child, at: offset + bytes.count)) } }
            return bytes
        }
        for chunk in chunks { payload.append(emit(chunk, at: 44 + size + payload.count)) }
        var result = header + directory + payload; put32(UInt32(result.count - 8), &result, 4); return result
    }
    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 255), UInt8(value >> 8)]) }
    private static func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
    private static func put16(_ value: UInt16, _ data: inout Data, _ at: Int) { data.replaceSubrange(at..<(at + 2), with: le16(value)) }
    private static func put32(_ value: UInt32, _ data: inout Data, _ at: Int) { data.replaceSubrange(at..<(at + 4), with: le32(value)) }
}
