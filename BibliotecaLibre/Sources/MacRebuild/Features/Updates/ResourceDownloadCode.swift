import Foundation
import CryptoKit
import LibronixCore

struct ResourceDownloadCode: Codable, Sendable {
    let version: Int
    let url: URL
    let key: String
    static func decode(_ text: String, embeddedKey: String? = ResourceDownloadKey.value) throws -> Self {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.hasPrefix("LX1.") || trimmed.hasPrefix("LX2.")), trimmed.count < 16_384 else { throw LibronError.invalid("Invalid download code") }
        var encoded = String(trimmed.dropFirst(4)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard var data = Data(base64Encoded: encoded) else { throw LibronError.invalid("Invalid download code") }
        let encrypted = trimmed.hasPrefix("LX2.")
        if encrypted {
            guard let embeddedKey, ResourceDownloadKey.validated(Data(embeddedKey.utf8)) != nil else {
                throw LibronError.invalid("This application does not contain the resource download key")
            }
            data = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: SHA256.hash(data: Data(embeddedKey.utf8))))
        }
        let code = try JSONDecoder().decode(Self.self, from: data)
        guard code.version == (encrypted ? 2 : 1), ResourceDownloadKey.validated(Data(code.key.utf8)) != nil,
              code.url.scheme == "https", code.url.host != nil, code.url.user == nil, code.url.password == nil else { throw LibronError.invalid("Invalid download code") }
        return code
    }

    static func encode(url: URL, embeddedKey: String? = ResourceDownloadKey.value) throws -> String {
        guard let embeddedKey, ResourceDownloadKey.validated(Data(embeddedKey.utf8)) != nil,
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw LibronError.invalid("Invalid download URL or missing resource key")
        }
        let payload = Self(version: 2, url: url, key: embeddedKey)
        let key = SymmetricKey(data: SHA256.hash(data: Data(embeddedKey.utf8)))
        guard let sealed = try AES.GCM.seal(JSONEncoder().encode(payload), using: key).combined else {
            throw LibronError.invalid("Could not encrypt download code")
        }
        return "LX2." + sealed.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func open(_ data: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: SHA256.hash(data: Data(key.utf8))))
    }
}
struct DownloadResourceMember: Codable, Sendable {
    let path: String
    let sha256: String
    let bytes: Int64
}
struct DownloadResourceEntry: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let packageName: String
    let url: URL?
    let sha256: String
    let bytes: Int64
    let hidden: Bool
    let members: [DownloadResourceMember]
    let originalManifestSHA: String
    func validate() throws {
        guard packageName.hasSuffix(".libron"), Self.safe(packageName), !packageName.contains("/"),
              bytes > 0, bytes <= 2_147_483_648, !members.isEmpty, members.count < 100_000,
              Set(members.map(\.path)).count == members.count,
              members.allSatisfy({ Self.safe($0.path) && $0.bytes >= 0 && $0.bytes <= 2_147_483_648 && $0.sha256.count == 64 }),
              members.contains(where: { $0.path == "manifest.json" }), sha256.count == 64,
              members.reduce(Int64(0), { $0 + $1.bytes }) < 16_000_000_000,
              let url, url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw LibronError.invalid("Invalid resource download manifest")
        }
    }
    static func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") &&
        !path.contains("\0") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    func matches(_ package: URL) throws -> Bool {
        guard let resource = try? LibronPackage.read(package).1, resource.id == id else { return false }
        for member in members {
            try Task.checkCancellation()
            let file = package.appendingPathComponent(member.path)
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let actual = try? LibronPackage.hash(file) else { return false }
            if member.path == "manifest.json" {
                guard actual == member.sha256 || actual == originalManifestSHA else { return false }
            } else if actual != member.sha256 { return false }
        }
        return true
    }
}
struct ResourceDownloadManifest: Codable, Sendable {
    let schemaVersion: Int
    let id: String
    let title: String
    let resources: [DownloadResourceEntry]
    func validate() throws {
        guard schemaVersion == 1, !resources.isEmpty, resources.count <= 50_000,
              Set(resources.map(\.id)).count == resources.count else { throw LibronError.invalid("Invalid collection manifest") }
        for entry in resources { try entry.validate() }
    }
}
