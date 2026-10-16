import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import LibronixCore

enum PostingsInspection {
    struct UsageError: Error, LocalizedError {
        var errorDescription: String? {
            "Usage: libronix-inspect postings FILE.LSF FILE.LIX (--dictionary-row N | --literal-key TEXT)"
        }
    }

    private struct Source: Encodable {
        let name: String
        let byteCount: UInt64
        let sha256: String
        let verifiedAfter: Bool
    }

    private struct Evidence: Encodable {
        let schemaVersion = 1
        let method = "Exact BWDX dictionary row; bounded legacy numeric postings"
        let originalEvaluationVerified = false
        let originalPositionUnitVerified = false
        let sources: [Source]
        let entry: LegacyBodyTermPostings
        let hitCount: Int
        let groupCount: Int
        let leadingWordMatchesGroupCount: Bool
    }

    private struct LiteralEvidence: Encodable {
        let schemaVersion = 1
        let method = "Exact unsigned-16-bit BWDX key scan; bounded legacy numeric postings"
        let originalEvaluationVerified = false
        let originalNormalizationVerified = false
        let originalPositionUnitVerified = false
        let sources: [Source]
        let selection: LegacyLiteralDictionaryLookup
        let entries: [LegacyBodyTermPostings]
        let hitCount: Int
    }

    static func run(_ arguments: [String]) throws -> Data {
        guard arguments.count == 4 else { throw UsageError() }
        let row: Int?
        switch arguments[2] {
        case "--dictionary-row":
            guard let value = Int(arguments[3]), value >= 0 else { throw UsageError() }
            row = value
        case "--literal-key":
            row = nil
        default:
            throw UsageError()
        }
        let lsf = URL(fileURLWithPath: arguments[0]), lix = URL(fileURLWithPath: arguments[1])
        let urls = [lsf, lix]
        let before = try urls.map(fingerprint)
        let selection: LegacyLiteralDictionaryLookup?
        let entries: [LegacyBodyTermPostings]
        if let row {
            selection = nil
            entries = [try LegacyPostingsReader.readBodyTerm(lsfURL: lsf, lixURL: lix, dictionaryRow: row)]
        } else {
            let found = try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix,
                units: Array(arguments[3].utf16))
            // Aggregate output guards do not claim native malformed-input behavior.
            guard found.matches.reduce(UInt64(0), { $0 + UInt64($1.expectedHitCount) }) <= 500_000 else {
                throw LegacyDictionaryError.limitExceeded
            }
            var decodedBytes = 0, results: [LegacyBodyTermPostings] = []
            for match in found.matches {
                try Task.checkCancellation()
                let entry = try LegacyPostingsReader.readBodyTerm(lsfURL: lsf, lixURL: lix,
                    dictionaryRow: match.dictionaryRow)
                guard entry.packetFileOffset == match.packetFileOffset,
                      entry.packetByteCount == match.packetByteCount,
                      entry.postings.expectedHitCount == match.expectedHitCount,
                      try LegacyDictionaryReader.decodeKey(entry.dictionaryKeyBytes) == match.key else {
                    throw LegacyIndicesError.sourceChanged
                }
                guard entry.postings.decodedByteCount <= 32 * 1024 * 1024 - decodedBytes else {
                    throw LegacyDictionaryError.limitExceeded
                }
                decodedBytes += entry.postings.decodedByteCount
                results.append(entry)
            }
            selection = found
            entries = results
        }
        var sources: [Source] = []
        for (index, url) in urls.enumerated() {
            let after = try fingerprint(url)
            guard before[index] == after else { throw LegacyIndicesError.sourceChanged }
            sources.append(Source(name: url.lastPathComponent, byteCount: after.bytes,
                                  sha256: after.sha256, verifiedAfter: true))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let selection {
            return try encoder.encode(LiteralEvidence(sources: sources, selection: selection,
                entries: entries, hitCount: entries.reduce(0) { $0 + $1.postings.hitCount }))
        }
        let entry = entries[0]
        return try encoder.encode(Evidence(sources: sources, entry: entry,
            hitCount: entry.postings.hitCount, groupCount: entry.postings.groups.count,
            leadingWordMatchesGroupCount: entry.postings.leadingWordMatchesGroupCount))
    }

    private struct Fingerprint: Equatable {
        let bytes: UInt64
        let sha256: String
    }

    private static func fingerprint(_ url: URL) throws -> Fingerprint {
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        var hash = SHA256(), bytes: UInt64 = 0
        while let chunk = try stream.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            bytes += UInt64(chunk.count)
            hash.update(data: chunk)
        }
        return Fingerprint(bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
