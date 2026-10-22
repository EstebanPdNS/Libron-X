import Foundation
import CryptoKit
import Testing
@testable import MacRebuild

struct IcedrivePublicDownloadTests {
    @Test func acceptsOnlySingleAnonymousFileRequests() throws {
        let prefix = "https://apis.icedrive.net/v3/webapp/download-multi&items="
        #expect(try IcedrivePublicDownload.fileID(URL(string: prefix + "file-3848524329&public=1")!) == 3_848_524_329)
        #expect(try IcedrivePublicDownload.fileID(URL(string: "https://example.com/catalog")!) == nil)
        for suffix in ["file-0&public=1", "file--1&public=1", "file-1,file-2&public=1", "folder-1&public=1", "file-1&public=0", "file-1&public=1?extra=1", "file-1&public=1#extra"] {
            #expect(throws: (any Error).self) { try IcedrivePublicDownload.fileID(URL(string: prefix + suffix)!) }
        }
    }

    @Test func validatesRemoteIdentitySizeAndDownloadHost() throws {
        func data(id: Int64 = 42, size: Int64 = 167, url: String = "https://ice-us-1.icedrive.io/download?p=temporary", count: Int = 1) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["error": false, "urls": Array(repeating: ["id": id, "filesize": size, "url": url] as [String: Any], count: count)])
        }
        #expect(try IcedrivePublicDownload.address(from: data(), fileID: 42, maximumBytes: 167).host == "ice-us-1.icedrive.io")
        for invalid in [try data(id: 43), try data(size: 168), try data(size: 0), try data(count: 2), try data(url: "https://icedrive.io.example.com/download?p=x"), try data(url: "http://ice-us-1.icedrive.io/download?p=x"), try data(url: "https://ice-us-1.icedrive.io/download"), Data(#"{"error":true,"message":"private"}"#.utf8)] {
            #expect(throws: (any Error).self) { try IcedrivePublicDownload.address(from: invalid, fileID: 42, maximumBytes: 167) }
        }
    }

    /// Opt-in live probe uses a user-provided public URL and its independently recorded encrypted hash.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_ICEDRIVE_PROBE_URL"] != nil))
    func anonymousTransportDownloadsVerifiedCiphertext() async throws {
        let environment = ProcessInfo.processInfo.environment
        let address = try #require(environment["LIBRONX_ICEDRIVE_PROBE_URL"])
        let url = try #require(URL(string: address))
        let expected = try #require(environment["LIBRONX_ICEDRIVE_PROBE_SHA256"])
        let file = try await AnonymousResourceTransport().fetch(url, maximumBytes: 65_536) { _ in }
        defer { try? FileManager.default.removeItem(at: file) }
        let data = try Data(contentsOf: file)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected)
    }
}
