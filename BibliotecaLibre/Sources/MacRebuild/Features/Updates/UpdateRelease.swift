import Foundation

// GitHub prerelease is authoritative for channel membership; SemVer is used for
// ordering, never publication date or the order returned by the API.
enum UpdateChannel: String, CaseIterable, Identifiable, Codable, Sendable {
    case stable, beta
    var id: String { rawValue }
    var title: String { self == .stable ? "Stable" : "Beta" }
}
struct ReleaseVersion: Comparable, Equatable, Sendable {
    let numbers: [Int]
    let prerelease: [String]
    init?(_ raw: String) {
        let value = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let metadata = value.components(separatedBy: "+")
        guard metadata.count <= 2, !metadata[0].isEmpty,
              metadata.count == 1 || !metadata[1].isEmpty else { return nil }
        let core = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = core[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        numbers = parts.map { Int($0)! } + Array(repeating: 0, count: 3-parts.count)
        prerelease = core.count == 2 ? core[1].components(separatedBy: ".") : []
        let labels = prerelease + (metadata.count == 2 ? metadata[1].components(separatedBy: ".") : [])
        guard labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }) else { return nil }
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty { return false }; if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if let x = Int(a), let y = Int(b) { return x < y }
            if Int(a) != nil { return true }; if Int(b) != nil { return false }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int
        let browser_download_url: URL
        let digest: String?
        var sha256: String? {
            guard let digest, digest.hasPrefix("sha256:") else { return nil }
            let hash = String(digest.dropFirst(7)).lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
            return hash
        }
    }
    let tag_name: String
    let prerelease: Bool
    let draft: Bool
    let html_url: URL
    let assets: [Asset]
    var version: ReleaseVersion? { ReleaseVersion(tag_name) }
    var appAsset: Asset? {
        assets.first { $0.name == "Libron-X-\(tag_name).zip" && Self.trustedAssetURL($0.browser_download_url) }
    }
    static func trustedAssetURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil &&
        url.path.hasPrefix("/EstebanPdNS/Libron-X/releases/download/")
    }
    static func newest(in releases: [Self], channel: UpdateChannel, installed: ReleaseVersion) -> Self? {
        releases.filter { release in
            guard !release.draft, channel == .beta || !release.prerelease,
                  let version = release.version, version > installed else { return false }
            // A stable release cannot carry a prerelease SemVer label.
            return channel == .beta || version.prerelease.isEmpty
        }.max { $0.version! < $1.version! }
    }
}

enum AppUpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
