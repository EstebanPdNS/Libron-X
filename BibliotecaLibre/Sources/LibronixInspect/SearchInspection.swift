import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import LibronixCore

enum SearchInspection {
    struct Options {
        let directory: URL
        let fileName: String
        let query: SearchQuery
        let evaluation: TextSearchOptions
        let budget: LibrarySearchBudget
        let unit: LibrarySearchUnit

        init(arguments: [String]) throws {
            guard let path = arguments.first, !path.hasPrefix("--") else { throw UsageError() }
            directory = URL(fileURLWithPath: path, isDirectory: true)
            var file: String?, queryText: String?
            var caseSensitive = false, diacriticSensitive = true, wholeWords = true
            var unit = LibrarySearchUnit.article
            var duration: Double = 60
            var maximumArticles = 20_000, maximumResults = 500, maximumOccurrences = 20_000
            var index = 1
            while index < arguments.count {
                let flag = arguments[index]
                if ["--case-sensitive", "--ignore-diacritics", "--substrings", "--verses"].contains(flag) {
                    if flag == "--case-sensitive" { caseSensitive = true }
                    if flag == "--ignore-diacritics" { diacriticSensitive = false }
                    if flag == "--substrings" { wholeWords = false }
                    if flag == "--verses" { unit = .bibleVerse }
                    index += 1; continue
                }
                guard index + 1 < arguments.count else { throw UsageError() }
                let value = arguments[index + 1]
                switch flag {
                case "--file":
                    guard file == nil, !value.isEmpty, !value.contains("/"), !value.contains("\\"), value != ".", value != ".." else { throw UsageError() }
                    file = value
                case "--query": guard queryText == nil else { throw UsageError() }; queryText = value
                case "--max-seconds": guard let number = Double(value) else { throw UsageError() }; duration = number
                case "--max-articles": guard let number = Int(value) else { throw UsageError() }; maximumArticles = number
                case "--max-results": guard let number = Int(value) else { throw UsageError() }; maximumResults = number
                case "--max-occurrences": guard let number = Int(value) else { throw UsageError() }; maximumOccurrences = number
                default: throw UsageError()
                }
                index += 2
            }
            guard let file, let queryText else { throw UsageError() }
            fileName = file
            self.unit = unit
            query = try SearchQueryParser.parse(queryText)
            evaluation = .init(caseSensitive: caseSensitive, diacriticSensitive: diacriticSensitive, wholeWords: wholeWords)
            budget = .init(maximumDurationSeconds: duration, maximumArticles: maximumArticles,
                maximumResults: maximumResults, maximumOccurrences: maximumOccurrences)
        }
    }

    struct UsageError: Error, LocalizedError {
        var errorDescription: String? {
            "Uso: libronix-inspect search /ruta/a/biblioteca --file RVR60.LSF --query '\"En el principio\"' [--verses] [--case-sensitive] [--ignore-diacritics] [--substrings] [--max-seconds N] [--max-articles N] [--max-results N] [--max-occurrences N]"
        }
    }

    /// An evidence projection contains counts, coordinates and hashes, never
    /// stored book text, snippets, article titles or private absolute paths.
    private struct Evidence: Encodable {
        let schemaVersion = 1
        let generatedUTC: Date
        let query: String
        let unit: String
        let scopeFile: String
        let options: [String: Bool]
        let budget: [String: Double]
        let coverageComplete: Bool
        let limitReason: String?
        let elapsedSeconds: Double
        let counts: [String: Int]
        let sources: [Source]
        let results: [Result]
        let errors: [Failure]
        let method: String
        let limitations: [String]
    }
    private struct Source: Encodable { let file: String; let size: UInt64; let sha256: String; let verifiedAfter: Bool }
    private struct Hit: Encodable { let locationUTF16: Int; let lengthUTF16: Int }
    private struct Result: Encodable {
        let sectionOrdinal: Int; let hitCount: Int; let hits: [Hit]; let decodedTextSHA256: String
        let bibleReference: String?; let verseRange: Hit?
    }
    private struct Failure: Encodable { let sectionOrdinal: Int?; let code: String }

    static func run(_ options: Options) async throws -> Data {
        let catalog = try await LibraryImporter().importDirectory(at: options.directory)
        let matches = catalog.resources.filter { $0.location.lastPathComponent == options.fileName }
        guard matches.count == 1, let resource = matches.first else {
            throw CocoaError(.fileReadInvalidFileName, userInfo: [NSLocalizedDescriptionKey:
                "El archivo seleccionado debe identificar exactamente un recurso del catálogo."])
        }
        let sourceURLs = [resource.location] + (resource.indexLocation.map { [$0] } ?? [])
        let initial = try sourceURLs.map { url in (url, try fingerprint(url)) }
        let report = try await LibrarySearchService().search(resources: [resource], query: options.query,
            options: options.evaluation, unit: options.unit, budget: options.budget)
        let sources = try initial.map { url, before in
            let after = try fingerprint(url)
            guard before == after else { throw LegacyIndicesError.sourceChanged }
            return Source(file: url.lastPathComponent, size: before.size, sha256: before.sha256, verifiedAfter: true)
        }
        let c = report.counters
        let evidence = Evidence(generatedUTC: Date(), query: options.query.source,
            unit: options.unit.rawValue, scopeFile: options.fileName,
            options: ["caseSensitive": options.evaluation.caseSensitive,
                      "diacriticSensitive": options.evaluation.diacriticSensitive, "wholeWords": options.evaluation.wholeWords],
            budget: ["maximumSeconds": options.budget.maximumDurationSeconds,
                     "maximumArticles": Double(options.budget.maximumArticles), "maximumResults": Double(options.budget.maximumResults),
                     "maximumOccurrences": Double(options.budget.maximumOccurrences)],
            coverageComplete: report.coverageComplete, limitReason: report.limitReason?.rawValue,
            elapsedSeconds: report.elapsedSeconds,
            counts: ["resourcesTotal": c.resourcesTotal, "resourcesCompleted": c.resourcesCompleted,
                     "resourcesIncompatible": c.resourcesIncompatible, "resourcesFailed": c.resourcesFailed,
                     "resourcesWithUnknownArticleTotal": c.resourcesWithUnknownArticleTotal,
                     "articlesTotalKnown": c.articlesTotalKnown, "articlesExamined": c.articlesExamined,
                     "articlesDecoded": c.articlesDecoded, "articlesFailed": c.articlesFailed,
                     "versesExamined": c.versesExamined, "matchingVerses": c.matchingVerses,
                     "matchingArticles": c.matchingArticles, "occurrencesObserved": c.occurrencesObserved,
                     "occurrencesReturned": c.occurrencesReturned, "resultsReturned": c.resultsReturned],
            sources: sources,
            results: report.results.map { result in .init(sectionOrdinal: result.sectionOrdinal,
                hitCount: result.hitCount, hits: result.hits.map { .init(locationUTF16: $0.range.location, lengthUTF16: $0.range.length) },
                decodedTextSHA256: result.decodedTextSHA256, bibleReference: result.bibleReference,
                verseRange: result.verseRange.map { .init(locationUTF16: $0.location, lengthUTF16: $0.length) }) },
            errors: report.resourceReports.flatMap { $0.errors.map { .init(sectionOrdinal: $0.sectionOrdinal, code: $0.code) } },
            method: report.scopeDescription,
            limitations: ["Independent decoded-text search; equivalence to original indexes or Windows results is not claimed.",
                          "Hashes and ranges identify decoded articles; styles, objects, language normalization and unsupported formats remain separate work.",
                          "No commercial book text, snippets, article titles or absolute library paths are included."])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(evidence)
    }

    private struct Fingerprint: Equatable { let size: UInt64; let sha256: String }
    private static func fingerprint(_ url: URL) throws -> Fingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), size: UInt64 = 0
        while let block = try handle.read(upToCount: 65_536), !block.isEmpty {
            try Task.checkCancellation()
            hash.update(data: block); size += UInt64(block.count)
        }
        return .init(size: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
