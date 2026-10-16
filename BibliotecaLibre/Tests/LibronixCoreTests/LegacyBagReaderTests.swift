import Foundation
import Testing
@testable import LibronixCore

@Suite struct LegacyBagReaderTests {
    @Test func directoryKeepsSourceOrderStateAndUnusedTrailingBytes() throws {
        let bytes = Data("first".utf8), second = Data("second".utf8)
        try withFile(BagFixture.file([("Map.BMP", bytes), ("icon.bmp", second)])) { url in
            let catalog = try LegacyBagReader.inspect(url)
            #expect(catalog.entries.map(\.name) == ["Map.BMP", "icon.bmp"])
            #expect(catalog.entries.map(\.ordinal) == [0, 1])
            #expect(catalog.directoryStateWord == 77 && catalog.trailingDirectoryBytes == 16)
            #expect(try LegacyBagReader.read(url, catalog: catalog, name: "mAP.bmp") == bytes)
        }
    }

    @Test func ambiguousNamesMalformedCountsAndUnterminatedNamesAreRejected() throws {
        let blocks = [LegacyBlock(tag: "bagf", offset: 100, length: 12, declaredChildren: 0, flags: 0)]
        var data = BagFixture.directory([("one.bmp", Data([1]))])
        BagFixture.put32(2, &data, 0)
        #expect(throws: LegacyBagError.invalidDirectory) { try LegacyBagReader.decodeDirectory(data, files: blocks) }
        data = BagFixture.directory([("one.bmp", Data([1]))])
        data.replaceSubrange(16..<272, with: Data(repeating: 65, count: 256))
        #expect(throws: LegacyBagError.invalidDirectory) { try LegacyBagReader.decodeDirectory(data, files: blocks) }
        let duplicate = BagFixture.directory([("one.bmp", Data([1])), ("ONE.BMP", Data([2]))])
        #expect(throws: LegacyBagError.invalidDirectory) { try LegacyBagReader.decodeDirectory(duplicate, files: blocks + blocks) }
    }

    @Test func independentDCLBlocksJoinAt8192AndPreserveTheFinalLength() throws {
        let source = Data((0..<17001).map { UInt8($0 % 251) })
        let compressed = BagFixture.compressed(source)
        #expect(try LegacyBagReader.decodeCompressed(compressed, expectedLength: source.count) == source)
        #expect(compressed[4] == 3)
    }

    @Test func corruptCompressionTablesAndUnsupportedVersionsCannotReturnPartialOutput() throws {
        let source = Data("Synthetic image bytes".utf8), valid = BagFixture.compressed(source)
        var version = valid; BagFixture.put32(0, &version, 0)
        #expect(throws: LegacyBagError.unsupportedCompression(0)) { try LegacyBagReader.decodeCompressed(version, expectedLength: source.count) }
        for broken in [Data(valid.prefix(7)), Data(valid.dropLast()), valid + Data([0])] {
            #expect(throws: (any Error).self) { try LegacyBagReader.decodeCompressed(broken, expectedLength: source.count) }
        }
        #expect(throws: LegacyBagError.invalidCompression) { try LegacyBagReader.decodeCompressed(valid, expectedLength: source.count + 1) }
        #expect(throws: LegacyBagError.assetLimit) { try LegacyBagReader.decodeCompressed(valid, expectedLength: 0) }
    }

    @Test func namesAreInternalIdentifiersAndSizeBudgetsAreEnforcedBeforeDecode() throws {
        let source = Data("Our bytes, unrelated to any external path".utf8)
        try withFile(BagFixture.file([("../../outside.bin", source)])) { url in
            let catalog = try LegacyBagReader.inspect(url)
            #expect(try LegacyBagReader.read(url, catalog: catalog, name: "../../outside.bin") == source)
            #expect(throws: LegacyBagError.assetLimit) { try LegacyBagReader.read(url, catalog: catalog, name: "../../outside.bin", maximumBytes: 4) }
            #expect(throws: LegacyBagError.assetNotFound("missing")) { try LegacyBagReader.read(url, catalog: catalog, name: "missing") }
        }
    }

    @Test func graphicsServiceDeduplicatesBytesWithinBudgetAndRejectsChangedSources() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".LSF")
        let data = Data("one image".utf8)
        try BagFixture.file([("image.bmp", data)]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = LegacyGraphicsService(), stamp = try LegacyGraphicsService.fileStamp(url)
        let result = try await service.load(url, graphics: [graphic("!image.bmp", 1), graphic("!IMAGE.BMP", 3)],
                                             expectedSource: stamp, maximumTotalBytes: data.count)
        #expect(result.assets.count == 2 && result.warnings.isEmpty)
        #expect(result.assets[0].data == data && result.assets[0].sha256 == result.assets[1].sha256)
        #expect(result.assets.map { $0.graphic.objectCharacterOffset } == [1, 3])
        let limited = try await service.load(url, graphics: [graphic("!image.bmp", 1)], expectedSource: stamp, maximumTotalBytes: 1)
        #expect(limited.assets.isEmpty && !limited.warnings.isEmpty)
        try FileManager.default.setAttributes([.modificationDate: stamp.modified.addingTimeInterval(5)], ofItemAtPath: url.path)
        await #expect(throws: LegacyIndicesError.sourceChanged) { try await service.load(url, graphics: [graphic("!image.bmp", 1)], expectedSource: stamp) }
    }

    @Test func externalAndMissingGraphicsRemainWarningsWithoutFetchingAnything() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".LSF")
        try BagFixture.file([("image.bmp", Data([1, 2, 3]))]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await LegacyGraphicsService().load(url,
            graphics: [graphic("https://invalid.example/image.bmp", 0), graphic("!missing.bmp", 1)],
            expectedSource: LegacyGraphicsService.fileStamp(url))
        #expect(result.assets.isEmpty && result.warnings.count == 2)
    }

    private func graphic(_ reference: String, _ offset: Int) -> LegacyGraphicRun {
        .init(sourceRunFlags: 0, attribute: nil, reference: reference, characterOffset: offset,
              decodedOffset: 0, fileOffset: nil, rawHeaderHex: "")
    }
    private func withFile(_ data: Data, body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".LSF")
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }; try body(url)
    }
}

private enum BagFixture {
    static func put32(_ value: UInt32, _ data: inout Data, _ offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8((value >> UInt32(index * 8)) & 255) }
    }
    static func put16(_ value: UInt16, _ data: inout Data, _ offset: Int) {
        data[offset] = UInt8(value & 255); data[offset + 1] = UInt8(value >> 8)
    }
    static func directory(_ files: [(String, Data)]) -> Data {
        var data = Data(repeating: 0, count: 8 + files.count * 264 + 16)
        put32(UInt32(files.count), &data, 0); put32(77, &data, 4)
        for (index, pair) in files.enumerated() {
            let start = 8 + index * 264
            put32(UInt32(pair.1.count), &data, start)
            data.replaceSubrange((start + 8)..<(start + 8 + pair.0.utf8.count), with: Data(pair.0.utf8))
        }
        return data
    }
    static func compressed(_ data: Data) -> Data {
        let count = (data.count + 8191) / 8192
        var pieces: [Data] = []
        for start in stride(from: 0, to: data.count, by: 8192) { pieces.append(literal(data.subdata(in: start..<min(data.count, start + 8192)))) }
        var header = Data(repeating: 0, count: 8 + count * 2)
        put32(0x20000001, &header, 0); put16(UInt16(count), &header, 4)
        put16(UInt16(data.count - (count - 1) * 8192), &header, 6)
        for (index, piece) in pieces.enumerated() { put16(UInt16(piece.count), &header, 8 + index * 2); header.append(piece) }
        return header
    }
    static func literal(_ data: Data) -> Data {
        var result = Data([0, 6]), buffer: UInt32 = 0, bits = 0
        func write(_ value: UInt32, _ count: Int) {
            buffer |= value << UInt32(bits); bits += count
            while bits >= 8 { result.append(UInt8(buffer & 255)); buffer >>= 8; bits -= 8 }
        }
        for byte in data { write(0, 1); write(UInt32(byte), 8) }
        write(1, 1); write(0, 7); write(255, 8)
        if bits > 0 { result.append(UInt8(buffer & 255)) }
        return result
    }
    static func file(_ assets: [(String, Data)]) -> Data {
        let chunks: [(String, Data)] = [("bdir", directory(assets))] + assets.map { ("bagf", compressed($0.1)) }
        let directorySize = 18 + (1 + chunks.count) * 18, groupHeader = 44 + directorySize
        var group = Data(), records: [(String, Int, Int, Int)] = []
        for (name, content) in chunks {
            var header = Data(name.utf8); header.append(Data(repeating: 0, count: 4)); put32(UInt32(content.count), &header, 4)
            records.append((name, groupHeader + 8 + group.count + 8, content.count, 0)); group.append(header); group.append(content)
        }
        records.insert(("BAGS", groupHeader + 8, group.count, chunks.count), at: 0)
        var file = Data(repeating: 0, count: groupHeader)
        file.replaceSubrange(0..<4, with: Data("LSFF".utf8)); file.replaceSubrange(8..<12, with: Data("GTTL".utf8))
        file.replaceSubrange(36..<40, with: Data("pcr ".utf8)); put32(UInt32(directorySize), &file, 40)
        file.replaceSubrange(44..<48, with: Data("LSFF".utf8)); file.replaceSubrange(48..<52, with: Data("GTTL".utf8))
        for (index, record) in records.enumerated() {
            let start = 44 + 18 + index * 18
            file.replaceSubrange(start..<(start + 4), with: Data(record.0.utf8))
            put32(UInt32(record.2), &file, start + 8); put32(UInt32(record.1), &file, start + 12); put16(UInt16(record.3), &file, start + 16)
        }
        var header = Data("BAGS".utf8); header.append(Data(repeating: 0, count: 4)); put32(UInt32(group.count), &header, 4)
        file.append(header); file.append(group); put32(UInt32(file.count - 8), &file, 4)
        return file
    }
}
