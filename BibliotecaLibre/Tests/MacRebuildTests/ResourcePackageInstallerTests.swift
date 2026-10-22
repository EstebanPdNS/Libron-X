import Foundation
import CryptoKit
import Testing
import LibronixCore
@testable import MacRebuild

private actor DownloadFixtureTransport: ResourceDownloadTransport {
    let responses: [URL: Data]
    var requests: [URL] = []
    init(_ responses: [URL: Data]) { self.responses = responses }
    func fetch(_ url: URL, maximumBytes: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        requests.append(url)
        guard let data = responses[url], data.count <= maximumBytes else { throw LibronError.invalid("Missing authored response") }
        try Task.checkCancellation()
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: target); progress(1); return target
    }
    func count() -> Int { requests.count }
}
@MainActor struct ResourcePackageInstallerTests {
    private let secret = "0123456789ABCDEFGHIJKLMNOPQRST"
    private func seal(_ plain: Data) throws -> Data {
        try #require(AES.GCM.seal(plain, using: SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))).combined)
    }
    /// Authored zlib stream with stored DEFLATE blocks, independent of the inflater.
    private func storedZlib(_ plain: Data) -> Data {
        var out = Data([0x78, 0x01]); let bytes = Array(plain)
        var cursor = 0
        repeat {
            let count = min(65_535, bytes.count - cursor), final = cursor + count == bytes.count
            let n = UInt16(count), inverse = ~n
            out.append(final ? 1 : 0)
            out.append(contentsOf: [UInt8(n & 255), UInt8(n >> 8), UInt8(inverse & 255), UInt8(inverse >> 8)])
            out.append(contentsOf: bytes[cursor..<(cursor + count)]); cursor += count
        } while cursor < bytes.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
        let adler = b << 16 | a
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 255), UInt8((adler >> 8) & 255), UInt8(adler & 255)])
        return out
    }
    private func packageFiles(_ package: URL) throws -> [URL] {
        let enumerator = try #require(FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey]))
        return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    @Test func installSkipsExistingAndRepairsWithoutRedownloadingObjects() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["An authored study resource."]]); defer { fixture.remove() }
        let source = try #require(fixture.resources.first)
        let package = try LibronPackage.create(source, in: fixture.root.appendingPathComponent("Source"), backup: false)
        let resource = try LibronPackage.read(package, verify: true).1
        let root = fixture.root.appendingPathComponent("Destination"), cache = fixture.root.appendingPathComponent("Cache")
        let manifestURL = URL(string: "https://example.com/collection")!
        var responses: [URL: Data] = [:], files: [ResourceCollectionFile] = []
        for url in try packageFiles(package) {
            let data = try Data(contentsOf: url), hash = ResourcePackageInstaller.hash(data)
            let encrypted = try seal(storedZlib(data)), address = URL(string: "https://example.com/objects/" + hash + ".lxblob")!
            responses[address] = encrypted
            files.append(.init(path: url.resolvingSymlinksInPath().pathComponents.dropFirst(package.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/"), sha256: hash, object: "objects/" + hash + ".lxblob",
                encryptedSHA256: ResourcePackageInstaller.hash(encrypted), downloadBytes: Int64(encrypted.count), bytes: Int64(data.count), codec: "zlib", url: address))
        }
        let entry = ResourceCollectionEntry(id: resource.id, title: resource.title, packageName: package.lastPathComponent, hidden: false, files: files)
        let manifest = ResourceCollectionManifest(format: "org.libron.download.collection", schemaVersion: 2, id: "test", title: "Fixture", resources: [entry])
        responses[manifestURL] = try seal(JSONEncoder().encode(manifest))
        let transport = DownloadFixtureTransport(responses)
        let installer = ResourcePackageInstaller(root: root, cache: cache, transport: transport)
        let code = ResourceDownloadCode(version: 2, url: manifestURL, key: secret)
        let first = try await installer.install(code) { _ in }
        #expect(first.new == [resource.title] && first.failed.isEmpty)
        let requests = await transport.count()
        let installed = try #require(LibronCatalog.load(from: root).resources.first?.packageLocation)
        #expect(try LibronPackage.read(installed, verify: true).1.id == source.id)
        let second = try await installer.install(code) { _ in }
        #expect(second.installed == [resource.title] && second.new.isEmpty)
        #expect(await transport.count() == requests + 1) // Only refresh the collection manifest.
        let payload = try LibronPackage.read(installed).0.payload.path
        try Data(repeating: 0, count: Int(try LibronPackage.read(installed).0.payload.byteCount)).write(to: installed.appendingPathComponent(payload))
        let repaired = try await installer.install(code) { _ in }
        #expect(repaired.updated == [resource.title] && repaired.failed.isEmpty)
        #expect(await transport.count() == requests + 2) // Verified cached objects repair the package.
        #expect(try LibronPackage.read(installed, verify: true).1.id == source.id)
        #expect(!((try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".download-") }))
    }
    @Test func pathsAndMalformedCompressionCannotEscapeTheLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["../outside", "/outside", "a/../../outside", "a//b", "a\\b", "a:b"] {
            #expect(throws: (any Error).self) { try ResourceDownloadPaths.member(path, under: root) }
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root.deletingLastPathComponent())
        #expect(throws: (any Error).self) { try ResourceDownloadPaths.member("linked/outside", under: root) }
        let data = Data("Verified resource".utf8), compressed = storedZlib(data)
        #expect(try ResourceDistributionCompression.inflate(compressed, expectedBytes: data.count) == data)
        #expect(throws: (any Error).self) { try ResourceDistributionCompression.inflate(compressed + Data([0]), expectedBytes: data.count) }
        #expect(throws: (any Error).self) { try ResourceDistributionCompression.inflate(compressed, expectedBytes: 2) }
        #expect(try ResourceDistributionCompression.inflate(storedZlib(Data()), expectedBytes: 0).isEmpty)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_DOWNLOAD_PROBE_CODE_FILE"] != nil))
    func privateDownloadProbeInstallsReadsAndSkipsExistingResource() async throws {
        let codePath = try #require(ProcessInfo.processInfo.environment["LIBRONX_DOWNLOAD_PROBE_CODE_FILE"])
        let keyPath = try #require(ProcessInfo.processInfo.environment["LIBRONX_DOWNLOAD_PROBE_KEY_FILE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("libron-live-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = try String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = try String(contentsOfFile: codePath, encoding: .utf8)
        let code = try ResourceDownloadCode.decode(text, embeddedKey: secret)
        let installer = ResourcePackageInstaller(root: root.appendingPathComponent("Library"), cache: root.appendingPathComponent("Cache"))
        let first = try await installer.install(code) { _ in }
        #expect(first.new.count == 1 && first.failed.isEmpty)
        let resources = try LibronCatalog.load(from: root.appendingPathComponent("Library")).resources
        let resource = try #require(resources.first)
        let page = try await ReaderSession.read(resource, .init(ordinal: 0))
        #expect(!page.text.isEmpty)
        let second = try await installer.install(code) { _ in }
        #expect(second.new.isEmpty && second.updated.isEmpty && second.installed.count == 1 && second.failed.isEmpty)
    }
}
