import Foundation
import Testing
@testable import LibronixCore

struct LibronixBookArchiveTests {
    private func le(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private func plain(offset: UInt64 = 104, name: String = "fixture.txt") -> Data {
        let payload = Data("Owned α 😀".utf8)
        var data = Data("LEFS".utf8) + le(0x0100_0000,4) + le(0,8) + le(12,4) + le(0,8) + le(20,4)
        data += le(104,8) + le(4,4) + le(16,4) + le(16,4) + le(1,4)
        data += le(offset,8) + le(UInt64(payload.count),8)
        let encoded = name.data(using: .utf16LittleEndian)!
        data += encoded + Data(repeating: 0, count: 32 - encoded.count)
        return data + payload
    }
    private func wrap(_ payload: Data, version: UInt32 = 0x0101_0000) -> Data {
        let header = Data("LTES".utf8) + le(UInt64(version),4) + le(UInt64(payload.count),8)
        var clear = (version == 0x0101_0000 ? Data(header.prefix(8)) : Data()) + payload
        while clear.count % 8 != 0 { clear.append(0) }
        var context = [UInt32](repeating: 0, count: 4)
        for (i,c) in "Libronix File".utf8.enumerated() { context[i & 3] = context[i & 3] &* 17 &+ UInt32(c) }
        var output = header
        for at in stride(from: 0, to: clear.count, by: 8) {
            func word(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(clear[offset + $1]) << ($1 * 8) } }
            var first = word(at), second = word(at + 4), sum: UInt32 = 0
            for _ in 0..<8 {
                first = first &+ ((((second << 4) ^ (second >> 5)) &+ second) ^ (sum &+ context[Int(sum & 3)]))
                sum = sum &+ 0x9e37_79b9
                second = second &+ ((((first << 4) ^ (first >> 5)) &+ first) ^ (sum &+ context[Int((sum >> 11) & 3)]))
            }
            output += le(UInt64(first),4) + le(UInt64(second),4)
        }
        return output
    }
    private func withFile(_ bytes: Data, _ action: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned.lbxlls"); try bytes.write(to: file); try action(file)
    }
    @Test func bothEnvelopeProfilesReadExactUnalignedMemberBytesWithoutChangingSource() throws {
        for version: UInt32 in [0x0100_0000,0x0101_0000] {
            let bytes = wrap(plain(), version: version)
            try withFile(bytes) { url in
                let archive = try LibronixBookArchive.inspect(at: url)
                #expect(archive.profile == version && archive.entries.map(\.path) == ["fixture.txt"])
                #expect(try archive.readEntry("fixture.txt") == Data("Owned α 😀".utf8))
                let output = url.deletingLastPathComponent().appendingPathComponent("copy.txt")
                try archive.copyEntry("fixture.txt", to: output)
                #expect(try Data(contentsOf: output) == Data("Owned α 😀".utf8))
                #expect(try Data(contentsOf: url) == bytes)
            }
        }
    }
    @Test func changedSourcesMissingMembersAndReadBudgetsFailExplicitly() throws {
        try withFile(wrap(plain())) { url in
            let archive = try LibronixBookArchive.inspect(at: url)
            #expect(throws: LibronixBookError.entryNotFound) { try archive.readEntry("absent") }
            #expect(throws: LibronixBookError.limitExceeded) { try archive.readEntry("fixture.txt", maximumBytes: 2) }
            #expect(throws: LibronixBookError.invalidDirectory) { try archive.copyEntry("fixture.txt", to: url) }
            try Data([0]).write(to: url)
            #expect(throws: LibronixBookError.sourceChanged) { try archive.readEntry("fixture.txt") }
        }
    }
    @Test func corruptVerificationUnknownProfilesUnsafeNamesAndOutOfBoundsEntriesAreRejected() throws {
        var corrupt = wrap(plain()); corrupt[16] ^= 1
        try withFile(corrupt) { url in #expect(throws: LibronixBookError.verificationFailed) { try LibronixBookArchive.inspect(at: url) } }
        var unknown = wrap(plain()); unknown[7] = 9
        try withFile(unknown) { url in #expect(throws: LibronixBookError.unsupportedProfile) { try LibronixBookArchive.inspect(at: url) } }
        for bytes in [wrap(plain(offset: 9999)), wrap(plain(name: "../bad")), Data(wrap(plain()).dropLast(1))] {
            try withFile(bytes) { url in #expect(throws: LibronixBookError.self) { try LibronixBookArchive.inspect(at: url) } }
        }
    }
}
