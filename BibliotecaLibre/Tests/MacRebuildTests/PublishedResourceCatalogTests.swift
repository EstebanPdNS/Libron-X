import Foundation
import Testing
@testable import MacRebuild

/// Private release inputs stay outside the repository. This exercises real anonymous transport.
struct PublishedResourceCatalogTests {
    private struct Receipt: Decodable {
        let file: String
        let id: String
        let resources: Int
        let bytes: Int
        let sha256: String
        let url: URL
        let codeFile: String
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_PUBLISHED_CATALOG_RECEIPTS"] != nil))
    func allPublishedCodesDecryptMatchingValidCatalogs() async throws {
        let environment = ProcessInfo.processInfo.environment
        let receiptsPath = try #require(environment["LIBRONX_PUBLISHED_CATALOG_RECEIPTS"])
        let keyPath = try #require(environment["LIBRONX_DOWNLOAD_PROBE_KEY_FILE"])
        let secret = try String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let receipts = try JSONDecoder().decode([Receipt].self, from: Data(contentsOf: URL(fileURLWithPath: receiptsPath)))
        #expect(!receipts.isEmpty)
        var resourceIDs: Set<String> = []
        for receipt in receipts {
            let text = try String(contentsOfFile: receipt.codeFile, encoding: .utf8)
            let code = try ResourceDownloadCode.decode(text, embeddedKey: secret)
            #expect(code.url == receipt.url)
            let file = try await AnonymousResourceTransport().fetch(code.url, maximumBytes: Int64(receipt.bytes)) { _ in }
            defer { try? FileManager.default.removeItem(at: file) }
            let data = try Data(contentsOf: file)
            #expect(data.count == receipt.bytes)
            #expect(ResourcePackageInstaller.hash(data) == receipt.sha256)
            let manifest = try JSONDecoder().decode(ResourceCollectionManifest.self, from: code.open(data))
            try manifest.validate()
            #expect(manifest.id == receipt.id)
            #expect(manifest.resources.count == receipt.resources)
            for resource in manifest.resources {
                resourceIDs.insert(resource.id)
                for member in resource.files {
                    let address = try manifest.downloadURL(for: member, manifestURL: code.url)
                    #expect(try IcedrivePublicDownload.fileID(address) != nil)
                }
            }
            for font in manifest.readingFonts ?? [] {
                let address = try manifest.downloadURL(for: font, manifestURL: code.url)
                #expect(try IcedrivePublicDownload.fileID(address) != nil)
            }
        }
        #expect(!resourceIDs.isEmpty)
    }
}
