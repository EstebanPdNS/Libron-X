import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct OriginalFavoriteNavigationTests {
    @Test func importedFavoriteOpensCheckedOriginalPosition() async throws {
        let fixture = try OriginalFavoriteFixture(); defer { fixture.remove() }
        let personal = WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: personal); workspace.resources = fixture.resources
        let xml = Data(#"<favorites-collection><title>Own</title><favorite command="jump|pos=LLS-AOL:0.12.0|ref=bible.64.1.1|res=LLS:1.0.3"><title>Own favorite</title></favorite></favorites-collection>"#.utf8)
        let favorite = try #require(FavoritesDocument.importingLegacyXML(xml).items.first)
        workspace.openFavorite(favorite)
        for _ in 0..<500 where workspace.originalFavoriteTask != nil || workspace.activeReader?.isLoading == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reader = try #require(workspace.activeReader)
        #expect(workspace.error == nil && reader.error == nil)
        #expect(reader.page?.text == "Edition A · John1")
        #expect(reader.selectedRange == NSRange(location: 12, length: 0))
        #expect(favorite.kind == .legacyCommand && favorite.legacyCommand != nil)
    }

    @Test func missingAmbiguousAndInvalidCommandsDoNotOpenAReader() throws {
        let fixture = try OriginalFavoriteFixture(); defer { fixture.remove() }
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")))
        let command = "jump|pos=LLS-AOL:0.12.0|res=LLS:1.0.3"
        let favorite = LibraryFavorite(title: "Own", kind: .legacyCommand, legacyCommand: command)
        workspace.openFavorite(favorite)
        #expect(workspace.error != nil && workspace.readers.isEmpty)
        let original = fixture.resources[0]
        let duplicate = LibraryResource(location: fixture.root.appendingPathComponent("duplicate.LSF"), title: "Duplicate", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName, legacyIdentifier: original.legacyIdentifier)
        workspace.resources = [original, duplicate]; workspace.error = nil
        workspace.openFavorite(favorite)
        #expect(workspace.error != nil && workspace.readers.isEmpty)
        workspace.resources = [original]; workspace.error = nil
        workspace.openFavorite(.init(title: "Invalid", kind: .legacyCommand, legacyCommand: "run|res=LLS:1.0.3"))
        #expect(workspace.error != nil && workspace.readers.isEmpty)
    }

    @Test func newerNavigationCancelsAnOriginalFavorite() async throws {
        let fixture = try OriginalFavoriteFixture(); defer { fixture.remove() }
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")))
        workspace.resources = fixture.resources
        workspace.openFavorite(.init(title: "Own", kind: .legacyCommand, legacyCommand: "jump|pos=LLS-AOL:0.12.0|res=LLS:1.0.3"))
        let newer = workspace.open(fixture.resources[1])
        for _ in 0..<500 where newer.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(workspace.originalFavoriteTask == nil && workspace.activeReader === newer)
        #expect(workspace.readers.count == 1 && newer.resource.id == fixture.resources[1].id)
    }

    @Test func corruptIndexDoesNotNavigate() async throws {
        let fixture = try OriginalFavoriteFixture(); defer { fixture.remove() }
        let index = try #require(fixture.resources[0].indexLocation)
        try Data("broken index".utf8).write(to: index)
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")))
        workspace.resources = fixture.resources
        workspace.openFavorite(.init(title: "Own", kind: .legacyCommand, legacyCommand: "jump|pos=LLS-AOL:0.12.0|res=LLS:1.0.3"))
        for _ in 0..<500 where workspace.originalFavoriteTask != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(workspace.originalFavoriteTask == nil && workspace.error != nil && workspace.readers.isEmpty)
    }
    @Test func importedFavoriteOpensAPairedBibleInsideAnLLS() async throws {
        let fixture = try OriginalFavoriteFixture(); defer { fixture.remove() }
        let original = fixture.resources[0], url = fixture.root.appendingPathComponent("owned.lbxlls")
        func le(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        func words(_ values: [UInt32]) -> Data { values.reduce(into: Data()) { $0 += le(UInt64($1), 4) } }
        let members = ["owned.LSF": try Data(contentsOf: original.location), "owned.LIX": try Data(contentsOf: #require(original.indexLocation)), "this.metadata.xml": Data("<lbx-resource guid=\"LLS:OWNED\"><metadata/></lbx-resource>".utf8)]
        let paths = members.keys.sorted(), start = 56 + paths.count * 144
        var directory = Data(), body = Data()
        for path in paths {
            let bytes = members[path]!, name = path.data(using: .utf16LittleEndian)!
            directory += le(UInt64(start + body.count), 8) + le(UInt64(bytes.count), 8) + name + Data(repeating: 0, count: 128 - name.count)
            body += bytes
        }
        let archive = Data("LEFS".utf8) + words([0x01000000,0,0,12,0,0,20]) + le(UInt64(start),8) + words([4,16,64,UInt32(paths.count)]) + directory + body
        let header = Data("LTES".utf8) + words([0x01010000]) + le(UInt64(archive.count),8)
        var clear = Data(header.prefix(8)) + archive
        while clear.count % 8 != 0 { clear.append(0) }
        var key = [UInt32](repeating: 0, count: 4)
        for (i, c) in "Libronix File".utf8.enumerated() { key[i & 3] = key[i & 3] &* 17 &+ UInt32(c) }
        var encrypted = header
        for at in stride(from: 0, to: clear.count, by: 8) {
            func word(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(clear[offset + $1]) << ($1 * 8) } }
            var a = word(at), b = word(at + 4), sum: UInt32 = 0
            for _ in 0..<8 {
                a = a &+ ((((b << 4) ^ (b >> 5)) &+ b) ^ (sum &+ key[Int(sum & 3)]))
                sum = sum &+ 0x9e3779b9
                b = b &+ ((((a << 4) ^ (a >> 5)) &+ a) ^ (sum &+ key[Int((sum >> 11) & 3)]))
            }
            encrypted += words([a,b])
        }
        try encrypted.write(to: url)
        let resource = LibraryResource(location: url, title: "Owned LLS", byteCount: Int64(encrypted.count), format: .libronixLLS, support: .metadataOnly, provenance: .fileName, legacyIdentifier: "LLS:OWNED")
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")))
        workspace.resources = [resource]
        workspace.openFavorite(.init(title: "Own", kind: .legacyCommand, legacyCommand: "jump|pos=LLS-AOL:0.12.0|res=LLS:OWNED"))
        for _ in 0..<500 where workspace.originalFavoriteTask != nil || workspace.activeReader?.isLoading == true { try await Task.sleep(for: .milliseconds(10)) }
        let reader = try #require(workspace.activeReader)
        #expect(workspace.error == nil && reader.error == nil && reader.resource.id == resource.id)
        #expect(reader.page?.text == "Edition A · John1" && reader.selectedRange == NSRange(location: 12, length: 0))
        workspace.shutdown()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_FAVORITE_CHECK"] != nil))
    func originalFavoriteResolvesAgainstTheOriginalLibrary() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_FAVORITE_CHECK"]))
        let data = try Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Libronix DLS/Favorites.xml"))
        let favorite = try #require(FavoritesDocument.importingLegacyXML(data).items.first { $0.kind == .legacyCommand })
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let personal = WorkspacePersonalState(url: temporary.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: personal)
        let destination = try LegacyJumpDestination.parse(#require(favorite.legacyCommand))
        let packages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "libron" }
        let resources = try packages.compactMap { package -> LibraryResource? in
            let manifestURL = package.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL), let manifest = try? JSONDecoder().decode(LibronManifest.self, from: data),
                  manifest.legacyIdentifier?.caseInsensitiveCompare(destination.resourceID) == .orderedSame else { return nil }
            return try LibronPackage.read(package).1
        }
        workspace.resources = resources
        workspace.openFavorite(favorite)
        for _ in 0..<1000 where workspace.originalFavoriteTask != nil || workspace.activeReader?.isLoading == true { try await Task.sleep(for: .milliseconds(10)) }
        if let error = workspace.error { print("Original favorite resolution: \(error)") }
        if let error = workspace.activeReader?.error { print("Original favorite reader: \(error)") }
        #expect(workspace.error == nil && workspace.activeReader?.error == nil && workspace.activeReader?.page != nil)
        workspace.shutdown()
    }

}
