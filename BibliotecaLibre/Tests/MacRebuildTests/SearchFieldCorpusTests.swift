import AppKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct SearchFieldCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_FIELD_CORPUS"] != nil))
    func sampledManagedSourceFieldsRetainSourceCoordinatesAndProvenance() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_FIELD_CORPUS"]))
        let resources = try LibronCatalog.load(from: root).resources
        let provider = WorkspaceSearchReader()
        for name in ["ELS_SPA.LSF", "rvr60.lbxlls", "La Armadura de Dios.refi", "Help-Shell-LDLS-es.lbxoeb"] {
            let resource = try #require(resources.first { $0.location.lastPathComponent == name })
            let prepared = try await provider.prepare(resource)
            var bodies = 0, titles = 0, examined = 0
            var options = TextSearchOptions(); options.wholeWords = false
            let sample = Array(prepared.articles.prefix(16)) + Array(prepared.articles.dropFirst(16).suffix(8))
            for article in sample {
                let decoded = try await provider.read(resource, article: article, prepared: prepared)
                let directory = try #require(decoded.fieldDirectory)
                try directory.validate(in: decoded.text)
                examined += 1
                let scope = decoded.searchRange ?? .init(location: 0, length: decoded.text.utf16.count)
                if let body = directory.regions[.body]?.first(where: { NSIntersectionRange($0.nsRange, scope.nsRange).length > 0 }) {
                    let text = (decoded.text as NSString).substring(with: NSIntersectionRange(body.nsRange, scope.nsRange))
                    if let token = text.split(whereSeparator: { !$0.isLetter }).first(where: { $0.count >= 4 }) {
                        let query = try SearchQueryParser.parse("body:\"" + token.prefix(24) + "\"")
                        let hit = try TextSearchEngine.search(query: query, in: decoded.text, options: options, fields: directory)
                        #expect(hit.matchesQuery && !hit.hits.isEmpty)
                        bodies += 1
                    }
                }
                if let title = directory.externalValues?[.title]?.first(where: { !$0.isEmpty }) {
                    let literal = String(title.prefix(24)).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let hit = try TextSearchEngine.search(query: SearchQueryParser.parse("title:\"" + literal + "\""), in: decoded.text, options: options, fields: directory)
                    #expect(hit.matchesQuery && !hit.externalHits.isEmpty && hit.hits.isEmpty)
                    titles += 1
                }
            }
            try await provider.verifyUnchanged(resource, prepared: prepared)
            if resource.format != .libronixOEB { #expect(bodies > 0) }
            if resource.format == .legacyLSF || resource.format == .libronixOEB { #expect(titles > 0) }
            if resource.format == .eSwordSQLite {
                // This genuine source has an empty Chapter column. A generated
                // numeric navigation label must never become a source title.
                #expect(titles == 0)
            }
            print("Field corpus sample \(name): \(examined) articles, \(bodies) body witnesses, \(titles) external title witnesses; source stamps unchanged")
        }
    }
}
