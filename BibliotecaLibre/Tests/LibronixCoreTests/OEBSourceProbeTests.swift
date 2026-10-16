import Foundation
import Testing
@testable import LibronixCore

struct OEBSourceProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_OEB_MEDIA"] != nil))
    func validateAllOriginalOEBDirectoriesAndMembers() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_OEB_MEDIA"]))
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "lbxoeb" }.sorted { $0.path < $1.path }
        var rows: [[String: Any]] = []
        let service = LibronixOEBService()
        for url in files {
            let before = try LegacyGraphicsService.fileStamp(url)
            do {
                let book = try await service.prepare(url)
                #expect(!book.directory.articles.isEmpty)
                let htmlPages = book.members.filter { LibronixOEBBook.mimeType($0.key) == "text/html" }
                for (path, data) in htmlPages {
                    let html = try #require(String(data: data, encoding: .utf8), "Non-UTF8 OEB page \(path)")
                    #expect(html.range(of: #"<head\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) != nil)
                }
                for article in book.directory.articles where !article.fragment.isEmpty {
                    let path = try #require(book.path(for: book.url(path: article.path)))
                    let bytes = try #require(book.members[path])
                    let html = try #require(String(data: bytes, encoding: .utf8))
                    let fragment = NSRegularExpression.escapedPattern(for: article.fragment)
                    let pattern = "(?i:\\b(?:id|name)\\s*=\\s*)(?:\"" + fragment + "\"|'" + fragment + "'|" + fragment + "(?=[\\s>]))"
                    #expect(html.range(of: pattern, options: [.regularExpression]) != nil, "Missing source article anchor \(article.fragment) in \(path)")
                }
                #expect(try LegacyGraphicsService.fileStamp(url) == before)
                rows.append(["file": url.path.replacingOccurrences(of: root.path + "/", with: ""), "articles": book.directory.articles.count,
                             "pages": book.directory.files.count, "htmlMembers": htmlPages.count, "members": book.members.count, "bytes": book.members.values.reduce(0) { $0 + $1.count }, "passed": true])
            } catch {
                Issue.record("OEB \(url.lastPathComponent): \(error)")
                rows.append(["file": url.lastPathComponent, "passed": false, "error": String(describing: error)])
            }
        }
        if let receipt = ProcessInfo.processInfo.environment["LIBRONX_OEB_AUDIT"] {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: receipt), options: .atomic)
        }
        print("Original OEB directory audit: \(rows.count) resources, \(rows.filter { $0["passed"] as? Bool == true }.count) passed")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_OEB_CORPUS"] != nil))
    func captureOriginalOEBTablesAndPages() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_OEB_CORPUS"]))
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_OEB_RECEIPT"]))
        for name in ["Help-Addin-AudioBible-en.lbxoeb", "Help-Addin-BibleAnalysis-es.lbxoeb", "Help-Shell-LDLS-es.lbxoeb", "Help-Addin-BibleTools-es.lbxoeb", "Help-Addin-PersonalBookBuilder-en.lbxoeb"] {
            let url = root.appendingPathComponent(name), before = try LegacyGraphicsService.fileStamp(url)
            let archive = try LibronixBookArchive.inspect(at: url)
            let folder = output.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for entry in archive.entries where entry.path.hasSuffix(".dat") && entry.path.hasPrefix("_") ||
                entry.path.hasSuffix(".html") || entry.path.hasSuffix(".css") || entry.path == "this.metadata.xml" {
                let destination = folder.appendingPathComponent(entry.path)
                try archive.copyEntry(entry.path, to: destination)
            }
            #expect(try LegacyGraphicsService.fileStamp(url) == before)
            print("OEB source sample \(name): entries=\(archive.entries.count)")
        }
    }
}
