import Foundation
import Testing
@testable import LibronixCore

struct LegacyResourceReaderTests {
    @Test func testMetadataAndPairIdentifierFromSyntheticFiles() throws {
        try withFiles { directory in
            let identifier = Data([1, 0, 0, 0, 3, 0, 0, 0, 53, 0])
            let lsf = directory.appendingPathComponent("sample.LSF")
            let lix = directory.appendingPathComponent("sample.LIX")
            try fixture(kind: "GTTL", blocks: [
                ("bkid", identifier),
                ("gtdt", displayTitle(Data("Manual sintético".data(using: .windowsCP1252)!))),
                ("marc", marc([
                    ("100", "1 \u{1f}aAutor de prueba."),
                    ("245", "10\u{1f}aTítulo de prueba\u{1f}bSubtítulo\u{1f}cResponsable de prueba."),
                    ("041", "0 \u{1f}aspa\u{1f}aeng"),
                    ("260", "  \u{1f}aCiudad\u{1f}bEditorial de prueba\u{1f}c2000.")
                ]))
            ]).write(to: lsf)
            try fixture(kind: "BIDX", blocks: [("bkid", Data([1, 0]) + identifier)]).write(to: lix)
            let result = try LegacyResourceReader.inspect(lsfURL: lsf, lixURL: lix)
            #expect(result.title == "Manual sintético")
            #expect(result.lsf.marcTitle == "Título de prueba | Subtítulo")
            #expect(result.lsf.author == "Autor de prueba.")
            #expect(result.lsf.responsibility == "Responsable de prueba.")
            #expect(result.lsf.declaredLanguages == ["spa", "eng"])
            #expect(result.lsf.publisher == "Editorial de prueba")
            #expect(result.identifiersMatch == true)
            #expect(result.warnings.isEmpty)
        }
    }

    @Test func testMetadataWithoutMARCAndNoIndexIsStillInspectable() throws {
        try withFiles { directory in
            let lsf = directory.appendingPathComponent("sample.LSF")
            try fixture(kind: "GTTL", blocks: [("gtdt", displayTitle(Data([0x47, 0x75, 0xed, 0x61, 0x20, 0xe1])))])
                .write(to: lsf)
            let result = try LegacyResourceReader.inspect(lsfURL: lsf)
            #expect(result.title == "Guía á")
            #expect(result.identifiersMatch == nil)
            #expect(result.lix == nil)
            #expect(result.warnings.contains { $0.contains("MARC") })
        }
    }

    @Test func testWrongPairIsReportedWithoutPretendingItMatches() throws {
        try withFiles { directory in
            let lsf = directory.appendingPathComponent("sample.LSF")
            let lix = directory.appendingPathComponent("sample.LIX")
            try fixture(kind: "GTTL", blocks: [("bkid", Data(repeating: 0, count: 10))]).write(to: lsf)
            try fixture(kind: "BIDX", blocks: [("bkid", Data(repeating: 1, count: 12))]).write(to: lix)
            let result = try LegacyResourceReader.inspect(lsfURL: lsf, lixURL: lix)
            #expect(result.identifiersMatch == false)
            #expect(result.warnings.contains { $0.contains("no coinciden") })
        }
    }

    @Test func testRejectsLTESInsteadOfTreatingItAsReadableBook() throws {
        try withFiles { directory in
            let url = directory.appendingPathComponent("opaque.lbxlls")
            var data = Data(repeating: 0, count: 64)
            data.replaceSubrange(0..<4, with: Data("LTES".utf8))
            try data.write(to: url)
            #expect(throws: LegacyReaderError.invalidSignature) {
                try LegacyResourceReader.inspect(lsfURL: url)
            }
        }
    }

    @Test func testRejectsWrongResourceKind() throws {
        try withFiles { directory in
            let url = directory.appendingPathComponent("wrong.LSF")
            try fixture(kind: "BIDX", blocks: []).write(to: url)
            #expect(throws: LegacyReaderError.wrongResourceType(expected: "GTTL", actual: "BIDX")) {
                try LegacyResourceReader.inspect(lsfURL: url)
            }
        }
    }

    @Test func testRejectsTruncationBeforeSeekingPayloads() throws {
        try withFiles { directory in
            let url = directory.appendingPathComponent("truncated.LSF")
            var data = fixture(kind: "GTTL", blocks: [("gtdt", displayTitle(Data("Test".utf8)))])
            data.removeLast()
            try data.write(to: url)
            #expect(throws: LegacyReaderError.declaredSizeMismatch) {
                try LegacyResourceReader.inspect(lsfURL: url)
            }
        }
    }

    @Test func testRejectsDirectoryRangeBeyondFile() throws {
        try withFiles { directory in
            let url = directory.appendingPathComponent("invalid-range.LSF")
            var data = fixture(kind: "GTTL", blocks: [("bkid", Data(repeating: 0, count: 10))])
            put32(UInt32.max, into: &data, at: 44 + 18 + 12)
            try data.write(to: url)
            #expect(throws: LegacyReaderError.invalidRange(tag: "bkid")) {
                try LegacyResourceReader.inspect(lsfURL: url)
            }
        }
    }

    @Test func testRefusesOversizedDirectoryAllocation() throws {
        try withFiles { directory in
            let url = directory.appendingPathComponent("huge-directory.LSF")
            var data = fixture(kind: "GTTL", blocks: [])
            put32(16 * 1024 * 1024 + 1, into: &data, at: 40)
            try data.write(to: url)
            #expect(throws: LegacyReaderError.directoryLimitExceeded) {
                try LegacyResourceReader.inspect(lsfURL: url)
            }
        }
    }

    @Test func testRefusesOversizedMetadataBlock() throws {
        try withFiles { directory in
            let url = directory.appendingPathComponent("huge-metadata.LSF")
            try fixture(kind: "GTTL", blocks: [("gtdt", Data(repeating: 0, count: 16 * 1024 + 1))]).write(to: url)
            #expect(throws: LegacyReaderError.readLimitExceeded) {
                try LegacyResourceReader.inspect(lsfURL: url)
            }
        }
    }

    @Test func testMalformedMARCIsDiagnosticAndDoesNotLoseDisplayTitle() throws {
        try withFiles { directory in
            let url = directory.appendingPathComponent("bad-marc.LSF")
            try fixture(kind: "GTTL", blocks: [
                ("gtdt", displayTitle(Data("Test title".utf8))),
                ("marc", Data("99999not a bibliographic record".utf8))
            ]).write(to: url)
            let result = try LegacyResourceReader.inspect(lsfURL: url)
            #expect(result.title == "Test title")
            #expect(result.lsf.marcTitle == nil)
            #expect(result.warnings.contains { $0.contains("MARC") })
        }
    }

    @Test func testMetadataHeaderMustMatchDirectory() throws {
        try withFiles { directory in
            let url = directory.appendingPathComponent("bad-block-header.LSF")
            var data = fixture(kind: "GTTL", blocks: [("bkid", Data(repeating: 0, count: 10))])
            data.replaceSubrange((44 + 36)..<(44 + 40), with: Data("oops".utf8))
            try data.write(to: url)
            #expect(throws: LegacyReaderError.invalidMetadata(tag: "bkid")) {
                try LegacyResourceReader.inspect(lsfURL: url)
            }
        }
    }

    private func withFiles(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func fixture(kind: String, blocks: [(String, Data)]) -> Data {
        let directorySize = 18 + blocks.count * 18
        var header = Data(repeating: 0, count: 44)
        header.replaceSubrange(0..<4, with: Data("LSFF".utf8))
        header.replaceSubrange(8..<12, with: Data(kind.utf8))
        header.replaceSubrange(36..<40, with: Data("pcr ".utf8))
        put32(UInt32(directorySize), into: &header, at: 40)
        var directory = Data(repeating: 0, count: directorySize)
        directory.replaceSubrange(0..<4, with: Data("LSFF".utf8))
        directory.replaceSubrange(4..<8, with: Data(kind.utf8))
        var payload = Data()
        for (index, pair) in blocks.enumerated() {
            let (tag, contents) = pair
            let entry = 18 + index * 18
            directory.replaceSubrange(entry..<(entry + 4), with: Data(tag.utf8))
            put32(UInt32(contents.count), into: &directory, at: entry + 8)
            put32(UInt32(44 + directorySize + payload.count + 8), into: &directory, at: entry + 12)
            var blockHeader = Data(tag.utf8) + Data(repeating: 0, count: 4)
            put32(UInt32(contents.count), into: &blockHeader, at: 4)
            payload.append(blockHeader)
            payload.append(contents)
        }
        var file = header + directory + payload
        put32(UInt32(file.count - 8), into: &file, at: 4)
        return file
    }

    private func displayTitle(_ title: Data) -> Data {
        var block = Data(repeating: 0, count: 74)
        block[72] = UInt8(title.count & 0xff)
        block[73] = UInt8(title.count >> 8)
        block.append(title)
        return block
    }

    private func marc(_ fields: [(String, String)]) -> Data {
        var fieldData = Data()
        var directory = ""
        for (tag, text) in fields {
            let bytes = text.data(using: .windowsCP1252)! + Data([0x1e])
            directory += tag + String(format: "%04d%05d", bytes.count, fieldData.count)
            fieldData.append(bytes)
        }
        var leader = Array(repeating: UInt8(32), count: 24)
        let base = 24 + directory.utf8.count + 1
        let size = base + fieldData.count + 1
        leader.replaceSubrange(0..<5, with: String(format: "%05d", size).utf8)
        leader.replaceSubrange(12..<17, with: String(format: "%05d", base).utf8)
        return Data([0, 0]) + Data(leader) + Data(directory.utf8) + Data([0x1e]) + fieldData + Data([0x1d])
    }

    private func put32(_ value: UInt32, into data: inout Data, at index: Int) {
        for shift in 0..<4 { data[index + shift] = UInt8((value >> UInt32(shift * 8)) & 0xff) }
    }
}
