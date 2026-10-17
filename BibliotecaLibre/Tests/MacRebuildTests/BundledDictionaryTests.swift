import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct BundledDictionaryTests {
    @Test func allTwelveOfflinePackagesRetainLicensesAndResolveRealWords() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_BUNDLED_CORPUS"] else { return }
        let root = URL(fileURLWithPath: path)
        let resources = try BundledDictionaries.resources(at: root)
        #expect(resources.count == 12)
        for language in ["es", "en", "pt", "it"] {
            #expect(resources.filter { $0.languages.first == language }.count == 3)
        }
        for resource in resources {
            let package = try #require(resource.packageLocation)
            _ = try LibronPackage.read(package, verify: true)
            #expect(resource.format == .libronDictionary)
            #expect(resource.libron?.evidence.contains { $0.field == "license" && !$0.value.isEmpty } == true)
            #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("ATTRIBUTION.txt").path))
            let query = ["es":"tierra", "en":"earth", "pt":"terra", "it":"terra"][resource.languages[0]]!
            let match = try #require(try LibronDictionaryDatabase.match(query.uppercased(), at: resource.location), "No \(query) in \(resource.title)")
            let page = try await ReaderSession.read(resource, .init(ordinal: match.ordinal))
            #expect(page.text.count > query.count && page.content?.plainText == page.text)
            #expect(page.sectionCount == (try LibronDictionaryDatabase.count(resource.location)))
            let last = try LibronDictionaryDatabase.page(resource.location, ordinal: page.sectionCount - 1)
            #expect(!last.headword.isEmpty && !last.body.isEmpty)
            #expect(try LibronDictionaryDatabase.match("' OR 1=1 --", at: resource.location) == nil)
        }
    }
}
