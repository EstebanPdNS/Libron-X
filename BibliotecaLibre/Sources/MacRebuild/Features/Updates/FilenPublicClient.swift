import Foundation
import CryptoKit

/// Anonymous public-link transport. Account sessions and cookies are never used.
/// Wire interoperability is based on Filen's published v3 protocol; no SDK is linked.
struct FilenPublicClient: Sendable {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    struct File: Sendable {
        let name: String
        let uuid: String
        let bucket: String
        let region: String
        let chunks: Int
        let size: Int
        let version: Int
        let key: String
    }
    struct Folder: Sendable { let files: [File] }
    private struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
        let status: Bool
        let message: String?
        let data: T?
    }
    private struct Info: Decodable, Sendable { let parent: String; let hasPassword: Bool; let downloadBtn: Bool }
    private struct Content: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let uuid: String; let bucket: String; let region: String
            let chunks: Int; let size: Int; let version: Int; let metadata: String
        }
        let files: [Item]
    }
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }
    static func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func keyBytes(_ value: String) throws -> Data {
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { throw Failure(message: "Unsupported Filen encryption key") }
        let characters = Array(value)
        return Data(stride(from: 0, to: characters.count, by: 2).map { UInt8(String(characters[$0...($0 + 1)]), radix: 16)! })
    }
    static func metadata(_ text: String, key: String) throws -> Data {
        let characters = Array(text)
        guard characters.count >= 27 else { throw Failure(message: "Invalid Filen metadata") }
        let version = String(characters.prefix(3))
        let nonce: Data, secret: Data, encoded: String
        if version == "003" {
            secret = try keyBytes(key)
            let hex = String(characters[3..<27])
            guard hex.count == 24, hex.allSatisfy(\.isHexDigit) else { throw Failure(message: "Invalid Filen nonce") }
            let bytes = Array(hex)
            nonce = Data(stride(from: 0, to: bytes.count, by: 2).map { UInt8(String(bytes[$0...($0 + 1)]), radix: 16)! })
            encoded = String(characters.dropFirst(27))
        } else if version == "002" {
            // PBKDF2-HMAC-SHA512 with one round, as specified by metadata v2.
            let password = Data(key.utf8)
            secret = Data(HMAC<SHA512>.authenticationCode(for: password + Data([0,0,0,1]), using: SymmetricKey(data: password)).prefix(32))
            nonce = Data(String(characters[3..<15]).utf8)
            encoded = String(characters.dropFirst(15))
        } else { throw Failure(message: "Unsupported Filen metadata version") }
        guard nonce.count == 12, let ciphertext = Data(base64Encoded: encoded) else { throw Failure(message: "Invalid Filen metadata encoding") }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: nonce + ciphertext), using: SymmetricKey(data: secret))
    }
    func folder(_ link: URL) async throws -> Folder {
        let components = link.pathComponents.filter { $0 != "/" }
        guard link.scheme == "https", ["filen.io", "app.filen.io"].contains(link.host ?? ""),
              components.count == 2, components[0] == "d", UUID(uuidString: components[1]) != nil,
              let key = link.fragment, [32,64].contains(key.count) else { throw Failure(message: "Use a Filen public folder link") }
        let uuid = components[1]
        let info: Info = try await post("/v3/dir/link/info", ["uuid": uuid])
        guard !info.hasPassword, info.downloadBtn else { throw Failure(message: "The Filen link must allow downloads without a password") }
        let emptyPassword = Self.hex(Insecure.SHA1.hash(data: Data(Self.hex(SHA512.hash(data: Data("empty".utf8))).utf8)))
        let content: Content = try await post("/v3/dir/link/content", ["uuid": uuid, "parent": info.parent, "password": emptyPassword])
        guard content.files.count <= 10_000 else { throw Failure(message: "Filen folder exceeds collection limit") }
        var files: [File] = []
        for entry in content.files {
            guard let metadata = try JSONSerialization.jsonObject(with: Self.metadata(entry.metadata, key: key)) as? [String: Any],
                  let name = metadata["name"] as? String, let fileKey = metadata["key"] as? String,
                  !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
                  UUID(uuidString: entry.uuid) != nil, entry.chunks > 0, entry.chunks <= 1024,
                  entry.size >= 0, entry.size <= 512 * 1024 * 1024,
                  [entry.bucket, entry.region].allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }),
                  [2,3].contains(entry.version) else { throw Failure(message: "Unsupported Filen public file") }
            files.append(File(name: name, uuid: entry.uuid, bucket: entry.bucket, region: entry.region,
                              chunks: entry.chunks, size: entry.size, version: entry.version, key: fileKey))
        }
        guard Set(files.map(\.name)).count == files.count else { throw Failure(message: "Duplicate Filen filenames") }
        return Folder(files: files)
    }
    func download(_ file: File, to destination: URL, progress: @Sendable (Int64, Int64) -> Void = { _,_ in }) async throws {
        let key = file.version == 3 ? try Self.keyBytes(file.key) : Data(file.key.utf8)
        guard key.count == 32 else { throw Failure(message: "Invalid Filen file key") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".filen-" + UUID().uuidString)
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            var written = 0
            for chunk in 0..<file.chunks {
                try Task.checkCancellation()
                let url = URL(string: "https://egest.filen.io/\(file.region)/\(file.bucket)/\(file.uuid)/\(chunk)")!
                let data = try await fetch(URLRequest(url: url), maximum: 2 * 1024 * 1024)
                let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key))
                guard decoded.count <= 1024 * 1024, written + decoded.count <= file.size else { throw Failure(message: "Invalid Filen chunk size") }
                try handle.write(contentsOf: decoded); written += decoded.count
                progress(Int64(written), Int64(file.size))
            }
            guard written == file.size else { throw Failure(message: "Incomplete Filen download") }
            try handle.close()
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch { try? handle.close(); try? FileManager.default.removeItem(at: temporary); throw error }
    }
    private func post<T: Decodable & Sendable>(_ path: String, _ body: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: "https://gateway.filen.io" + path)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.hex(SHA512.hash(data: request.httpBody!)), forHTTPHeaderField: "Checksum")
        let response = try JSONDecoder().decode(Envelope<T>.self, from: await fetch(request, maximum: 32 * 1024 * 1024))
        guard response.status, let data = response.data else { throw Failure(message: response.message ?? "Filen rejected the public link") }
        return data
    }
    private func fetch(_ request: URLRequest, maximum: Int) async throws -> Data {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let (file, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else { throw Failure(message: "Invalid Filen response") }
            if [429,500,502,503,504].contains(http.statusCode), attempt < 2 {
                try await Task.sleep(for: .seconds(1 << attempt)); continue
            }
            guard (200..<300).contains(http.statusCode),
                  (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximum + 1) <= maximum else { throw Failure(message: "Filen download failed (HTTP \(http.statusCode))") }
            return try Data(contentsOf: file)
        }
        throw Failure(message: "Filen is temporarily unavailable")
    }
}
