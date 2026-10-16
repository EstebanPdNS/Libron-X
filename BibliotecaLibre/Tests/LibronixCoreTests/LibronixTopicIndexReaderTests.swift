import Foundation
import Testing
@testable import LibronixCore

struct LibronixTopicIndexReaderTests {
    private func le(_ value: Int, _ count: Int = 4) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private func variable(_ value: Int) -> Data {
        var value = value, result = Data()
        repeat { let byte = UInt8(value & 127); value >>= 7; result.append(byte | (value > 0 ? 128 : 0)) } while value > 0
        return result
    }
    private func fixture(version: Int = 2, dangling: Bool = false, cyclic: Bool = false, canonicalVariants: Bool = false) -> Data {
        let encoding = version == 1 ? 2 : 4
        let word = version == 1 ? Data("Creación".utf8) : Data([67,114,101,97,99,105,243,110])
        let text = variable(word.count) + word
        var words = le(4) + Data([canonicalVariants ? 2 : 1, cyclic ? 0 : 1])
        if cyclic { words += le(4) + le(4) }
        words += text + variable(1) + variable(dangling ? 8 : 7)
        let decomposed = Data("Creacio\u{301}n".utf8)
        let extra = variable(decomposed.count) + decomposed
        if canonicalVariants { words += extra + variable(1) + variable(7) }
        let refs = le(4) + Data([1,1]) + variable(7) + variable(canonicalVariants ? 2 : 1) + text + (canonicalVariants ? extra : Data())
        let name = "topics".data(using: .utf16LittleEndian)!
        let directory = variable(6) + name + variable(encoding) + le(33) + le(33 + words.count)
        let length = 33 + words.count + refs.count + directory.count
        var topic = Data("TO".utf8) + le(version,2) + le(length) + Data(repeating:0,count:19)
        topic += le(1,2) + le(33 + words.count + refs.count) + words + refs + directory
        let start = version == 3 ? 32 : 28, fullLength = start + topic.count
        return Data("IX".utf8) + le(version,2) + le(fullLength) + le(1,2) + le(0,2) + le(0,2)
            + (version == 3 ? le(0) : Data()) + Data("topics\0\0\0\0".utf8) + le(start) + topic
    }
    @Test func canonicalEquivalenceDoesNotEraseDistinctSourceKeyUnits() throws {
        let topics = try LibronixTopicIndexReader.read(fixture(version:1,canonicalVariants:true))[0].topics
        #expect(topics.count == 2 && topics[0].text == topics[1].text)
        #expect(Array(topics[0].text.utf16) != Array(topics[1].text.utf16))
    }
    @Test func cancellationBeforeReadingNeverProducesPartialTrees() async throws {
        let bytes = fixture()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try LibronixTopicIndexReader.read(bytes)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func bothProfilesDecodeActualKeysAndReferentsWithoutInventingSectionOrdinals() throws {
        for version in [1,2,3] {
            let indexes = try LibronixTopicIndexReader.read(fixture(version:version))
            #expect(indexes.count == 1 && indexes[0].name == "topics")
            #expect(indexes[0].topics == [.init(text:"Creación",referents:[7])])
            #expect(indexes[0].labelsByReferent == [7:["Creación"]])
        }
    }
    @Test func everyTruncationDanglingAssociationsAndCyclesFailWithoutPartialResults() throws {
        let bytes = fixture()
        for end in 0..<bytes.count {
            #expect(throws: (any Error).self) { try LibronixTopicIndexReader.read(Data(bytes.prefix(end))) }
        }
        #expect(throws: LibronixTopicIndexFailure.malformed) { try LibronixTopicIndexReader.read(fixture(dangling:true)) }
        #expect(throws: LibronixTopicIndexFailure.malformed) { try LibronixTopicIndexReader.read(fixture(cyclic:true)) }
        var unknown = bytes; unknown[2] = 9
        #expect(throws: LibronixTopicIndexFailure.unsupportedProfile) { try LibronixTopicIndexReader.read(unknown) }
        var futureFlags = fixture(version:3); futureFlags[14] = 1
        #expect(throws: LibronixTopicIndexFailure.unsupportedProfile) { try LibronixTopicIndexReader.read(futureFlags) }
        var oversized = Data("LZCS".utf8) + le(0x01000000) + le(24) + le(64 * 1024 * 1024 + 1) + le(0)
        oversized += Data(repeating:0,count:16)
        #expect(throws: LibronixTopicIndexFailure.limitExceeded) { try LibronixTopicIndexReader.read(oversized) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"] != nil))
    func actualTopicTreesIncludeMapIndexesAndCompressedMultilingualDictionary() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"]))
        let expectedHashes = [
            "STRDICTES.lbxlls#topics": "d9299769345cb9da34c4e868ec62fb02d480f44e84af3cef02d86bd4c848d03b",
            "17cual.lbxlls#topics": "dcc5ae161f2ca5a09441b4c3873157163aa221e47e01906afb4267dbc7d119e2",
            "LBLAMAPS.lbxlls#topics": "4920d13be0dbe7c2a08c95af4a4f46870f0ee752ed27a20cc8204fbc6750f0ee",
            "DXMAPSET.lbxlls#city": "3b373baf0dd315a5051ef8a4735dfc47f17530048fcf843ab9857d6bcbffcb27",
            "DXMAPSET.lbxlls#feature": "a04816c6b38f7c82ee19b8fb183b8244e94d14dd193bcb51e41bd6995d2b96f9",
            "DXMAPSET.lbxlls#region": "3908cf6af25429611c2861bf68cf5aa2538556f83703af4d2dbccd6a18e1d20d",
            "DXMAPSET.lbxlls#topics": "d340388be0d6a9d9be20a50c5f0016b553d3eee4e7fdfe89e2d05df3c4943985",
            "DXMAPSET.lbxlls#water": "488609205ae6160023493f2182ff22c91f5b6e42dcca0e9306c9537f16a5939d"
        ]
        var receipt: [[String:Any]] = []
        for name in ["17cual.lbxlls", "LBLAMAPS.lbxlls", "DXMAPSET.lbxlls", "STRDICTES.lbxlls"] {
            let url = root.appendingPathComponent(name), stamp = try LegacyGraphicsService.fileStamp(url)
            let archive = try LibronixBookArchive.inspect(at:url)
            let indexes = try LibronixTopicIndexReader.read(archive.readEntry("fullindex.dat",maximumBytes:32*1024*1024))
            #expect(Set(indexes.map(\.name)) == Set(try archive.metadata().declaredTopicIndexes.map(\.name)))
            #expect(indexes.allSatisfy { !$0.topics.isEmpty && !$0.labelsByReferent.isEmpty })
            if name == "17cual.lbxlls" { #expect(indexes[0].topics.count == 77 && indexes[0].labelsByReferent.count == 49) }
            if name == "LBLAMAPS.lbxlls" { #expect(indexes[0].topics.count == 504 && indexes[0].labelsByReferent.count == 11) }
            if name == "DXMAPSET.lbxlls" {
                #expect(indexes.map(\.name) == ["city","feature","region","topics","water"])
                #expect(indexes.map { $0.topics.count } == [274,217,236,1141,37])
            }
            for index in indexes {
                let forward: [[Any]] = index.topics.map { [$0.text, $0.referents] }
                let reverse: [[Any]] = index.labelsByReferent.keys.sorted().map { [$0, index.labelsByReferent[$0]!] }
                let canonical = try JSONSerialization.data(withJSONObject:[forward,reverse],options:[.withoutEscapingSlashes])
                #expect(LibrarySearchService.textFingerprint(String(decoding:canonical,as:UTF8.self)) == expectedHashes[name + "#" + index.name])
            }
            #expect(try LegacyGraphicsService.fileStamp(url) == stamp)
            receipt.append(["file":name,"indexes":indexes.map { ["name":$0.name,"encoding":$0.stringEncoding,"topics":$0.topics.count,"referents":$0.labelsByReferent.count] as [String:Any] },"sourceUnchanged":true])
        }
        if let path = ProcessInfo.processInfo.environment["LIBRONX_TOPIC_TREE_RECEIPT"] {
            try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path),options:.atomic)
        }
    }
}
