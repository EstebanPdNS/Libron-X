import Foundation
import CryptoKit
import Testing
@testable import MacRebuild

private final class UpdateURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var responses: [URL: Data] = [:]
    static func register(_ url: URL, data: Data) { lock.lock(); defer { lock.unlock() }; responses[url] = data }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let data = request.url.flatMap { Self.responses[$0] }; Self.lock.unlock()
        guard let url = request.url, let data else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct AppUpdateTests {
    private func release(_ tag: String, beta: Bool = false, draft: Bool = false, data: Data? = nil, hash: String? = nil) throws -> GitHubRelease {
        let digest = hash ?? data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? String(repeating: "a", count: 64)
        let object: [String: Any] = ["tag_name": tag, "prerelease": beta, "draft": draft,
            "html_url": "https://github.com/EstebanPdNS/Libron-X/releases/tag/\(tag)",
            "assets": [["name": "Libron-X-\(tag).zip", "size": data?.count ?? 10,
                        "browser_download_url": "https://github.com/EstebanPdNS/Libron-X/releases/download/\(tag)/Libron-X-\(tag).zip", "digest": "sha256:\(digest)"]]]
        return try JSONDecoder().decode(GitHubRelease.self, from: JSONSerialization.data(withJSONObject: object))
    }
    @Test func semverAndChannelsDoNotDowngradeOrInstallDrafts() throws {
        let releases = try [release("v0.2.0-beta.11", beta: true), release("v0.2.0-beta.2", beta: true),
                            release("v0.1.2"), release("v5.0", draft: true), release("nonsense")]
        let current = ReleaseVersion("0.1")!
        #expect(ReleaseVersion("v0.1") == ReleaseVersion("0.1.0"))
        #expect(ReleaseVersion("1.0.0-beta.2")! < ReleaseVersion("1.0.0-beta.11")!)
        #expect(ReleaseVersion("1.0.0-beta.11")! < ReleaseVersion("1.0.0")!)
        #expect(GitHubRelease.newest(in: releases, channel: .stable, installed: current)?.tag_name == "v0.1.2")
        #expect(GitHubRelease.newest(in: releases, channel: .beta, installed: current)?.tag_name == "v0.2.0-beta.11")
        #expect(GitHubRelease.newest(in: releases, channel: .stable, installed: ReleaseVersion("0.3")!) == nil)
        #expect(GitHubRelease.newest(in: [try release("v0.1", beta: true)], channel: .stable, installed: current) == nil)
    }
    @Test func invalidReleaseTagsCannotCrashOrBecomeUpdateCandidates() {
        for value in ["", "v", ".", "1..0", "1.2.3.4", "1.0.0-", "1.0.0-beta..2", "1+", "1+a+b", "1.0/a", "١.٢"] {
            #expect(ReleaseVersion(value) == nil)
        }
    }
    @Test func assetTrustRejectsOtherRepositoriesAndNonHTTPS() {
        for url in ["http://github.com/EstebanPdNS/Libron-X/releases/download/v1/x.zip",
                    "https://github.com/other/Libron-X/releases/download/v1/x.zip",
                    "https://evil.example/EstebanPdNS/Libron-X/releases/download/v1/x.zip"] {
            #expect(!GitHubRelease.trustedAssetURL(URL(string: url)!))
        }
    }
    private func fixture() throws -> (URL, URL, Data) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("libronx-updater-test-\(UUID())")
        let app = root.appendingPathComponent("payload/Libron-X.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture.c")
        try "int main(void) { return 0; }".write(to: source, atomically: true, encoding: .utf8)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        try run("/usr/bin/xcrun", ["clang", "-arch", arch, source.path, "-o", app.appendingPathComponent("Contents/MacOS/LibronXRebuild").path])
        let plist = ["CFBundleIdentifier": "org.libronx.mac.rebuild", "CFBundleExecutable": "LibronXRebuild",
                     "CFBundleShortVersionString": "9.0.0", "CFBundleVersion": "900", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try "new-version".write(to: app.appendingPathComponent("Contents/Resources/marker"), atomically: true, encoding: .utf8)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        let archive = root.appendingPathComponent("update.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
        let installed = root.appendingPathComponent("Installed.app")
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        try "old-version".write(to: installed.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        return (root, installed, try Data(contentsOf: archive))
    }
    private func service(for release: GitHubRelease, data: Data) -> GitHubUpdateService {
        UpdateURLProtocol.register(release.appAsset!.browser_download_url, data: data)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UpdateURLProtocol.self]
        return GitHubUpdateService(session: URLSession(configuration: configuration))
    }
    private func run(_ tool: String, _ args: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = args
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.standardError
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    @Test func downloadVerificationStageAndExitInstallerPreserveOriginalUntilReplacement() async throws {
        let (root, installed, data) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let release = try release("v9.0.0", data: data)
        let prepared = try await service(for: release, data: data).prepare(release, installedApp: installed)
        defer { prepared.discard() }
        #expect(try String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8) == "old-version")
        try run("/bin/sh", [prepared.helper.path, "999999", prepared.stagedApp.path, installed.path, prepared.backup.path,
                            "no", prepared.workDirectory.appendingPathComponent("result.txt").path])
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8) == "new-version")
        #expect(try String(contentsOf: prepared.backup.appendingPathComponent("marker"), encoding: .utf8) == "old-version")
        #expect(try String(contentsOf: prepared.workDirectory.appendingPathComponent("result.txt"), encoding: .utf8) == "installed\n")
    }
    @Test func corruptedDownloadNeverReplacesInstalledApplication() async throws {
        let (root, installed, data) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let release = try release("v9.0.0", data: data, hash: String(repeating: "0", count: 64))
        await #expect(throws: (any Error).self) { _ = try await service(for: release, data: data).prepare(release, installedApp: installed) }
        #expect(try String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8) == "old-version")
    }
    @Test func tamperedStagedAppFailsBeforeMovingOriginal() async throws {
        let (root, installed, data) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let release = try release("v9.0.0", data: data)
        let prepared = try await service(for: release, data: data).prepare(release, installedApp: installed)
        defer { prepared.discard() }
        try "tampered".write(to: prepared.stagedApp.appendingPathComponent("Contents/Resources/marker"), atomically: true, encoding: .utf8)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let result = prepared.workDirectory.appendingPathComponent("result.txt")
        process.arguments = [prepared.helper.path, "999999", prepared.stagedApp.path, installed.path, prepared.backup.path, "no", result.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.standardError
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus != 0)
        #expect(try String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8) == "old-version")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_LIVE_UPDATE_TEST"] == "1"))
    func liveGitHubAssetCanBeDownloadedVerifiedAndStagedWithoutReplacingTheApp() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("libronx-live-update-\(UUID())")
        let installed = root.appendingPathComponent("Libron-X.app")
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let service = GitHubUpdateService()
        let releases = try await service.releases()
        let latest = try #require(releases.filter { !$0.draft && $0.appAsset?.sha256 != nil && $0.version != nil }
            .max { $0.version! < $1.version! })
        let result = try await service.prepare(latest, installedApp: installed)
        defer { result.discard() }
        #expect(fm.fileExists(atPath: result.stagedApp.appendingPathComponent("Contents/MacOS/LibronXRebuild").path))
        #expect(!fm.fileExists(atPath: installed.appendingPathComponent("Contents").path))
        print("LIVE_UPDATE_VERIFIED " + latest.tag_name + " " + (latest.appAsset?.digest ?? ""))
    }
    @MainActor @Test func updateOptionsPersistAndSwitchingChannelsInvalidatesResults() throws {
        let name = "updater-\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let updater = AppUpdater(defaults: defaults)
        updater.channel = .beta; updater.automaticChecks = false; updater.automaticInstall = false
        let restored = AppUpdater(defaults: defaults)
        #expect(restored.channel == .beta && !restored.automaticChecks && !restored.automaticInstall)
        restored.channel = .stable
        #expect(restored.available == nil && restored.prepared == nil && !restored.isBusy)
    }
}
