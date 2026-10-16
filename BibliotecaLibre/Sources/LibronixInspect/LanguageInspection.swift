import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import LibronixCore

enum LanguageInspection {
    struct UsageError: Error, LocalizedError {
        var errorDescription: String? {
            "Usage: libronix-inspect language FILE [--profile ID] [--compare LEFT RIGHT] (ID: unsigned decimal or 0x hex; comparison requires --profile)"
        }
    }

    private struct Options {
        let path: String
        var profile: UInt16?
        var operands: (String, String)?

        init(_ arguments: [String]) throws {
            guard let path = arguments.first, !path.hasPrefix("--") else { throw UsageError() }
            self.path = path
            var index = 1
            while index < arguments.count {
                switch arguments[index] {
                case "--profile":
                    guard profile == nil, index + 1 < arguments.count else { throw UsageError() }
                    let raw = arguments[index + 1]
                    let digits = raw.hasPrefix("0x") || raw.hasPrefix("0X") ? String(raw.dropFirst(2)) : raw
                    let radix = digits == raw ? 10 : 16
                    guard !digits.isEmpty, digits.utf8.allSatisfy({
                        (48...57).contains($0) || (radix == 16 && ((65...70).contains($0) || (97...102).contains($0)))
                    }), let value = UInt16(digits, radix: radix) else { throw UsageError() }
                    profile = value; index += 2
                case "--compare":
                    guard operands == nil, index + 2 < arguments.count else { throw UsageError() }
                    operands = (arguments[index + 1], arguments[index + 2]); index += 3
                default:
                    throw UsageError()
                }
            }
            guard operands == nil || profile != nil else { throw UsageError() }
        }
    }

    private struct Profile: Encodable {
        let serializedVersion: UInt16?
        let languageIdentifier: UInt16
        let unitMapIdentifier: UInt16
        let collationIdentifier: UInt16
        let moduleNameByteCount: Int
        let nonemptyCallbackSlots: [Int]
        let packetByteCount: Int
        let packetSHA256: String

        init(_ value: LegacyLanguageProfile) {
            serializedVersion = value.serializedVersion
            languageIdentifier = value.languageIdentifier; unitMapIdentifier = value.unitMapIdentifier
            collationIdentifier = value.collationIdentifier; moduleNameByteCount = value.moduleNameBytes.count
            nonemptyCallbackSlots = value.callbackNameBytes.indices.filter { !value.callbackNameBytes[$0].isEmpty }
            packetByteCount = value.rawPacket.count; packetSHA256 = LanguageInspection.hash(value.rawPacket)
        }
    }

    private struct Collation: Encodable {
        let identifier: UInt16
        let rowCount: Int
        let maximumPrimaryWeight: UInt16
        let packetByteCount: Int
        let packetSHA256: String

        init(_ value: LegacyCollationTable) {
            identifier = value.identifier; rowCount = value.rows.count
            maximumPrimaryWeight = value.maximumPrimaryWeight
            packetByteCount = value.rawPacket.count; packetSHA256 = LanguageInspection.hash(value.rawPacket)
        }
    }

    private struct Comparison: Encodable {
        let method = "Supported serialized weighted branch; raw UTF16 operands"
        let leftUnitCount: Int
        let rightUnitCount: Int
        let ordering: Int
    }

    private struct Source: Encodable, Equatable {
        let name: String
        let byteCount: Int
        let sha256: String
    }

    private struct Evidence: Encodable {
        let schemaVersion = 1
        let method = "Bounded LSFF/LANG serialized definitions; explicit profile selection"
        let nativeModuleLoaded = false
        let originalLiveContextVerified = false
        let originalEvaluationVerified = false
        let normalizationApplied = false
        let sourceVerifiedAfter: Bool
        let source: Source
        let directoryRecordCount: Int
        let profiles: [Profile]
        let collations: [Collation]
        let selectedProfile: Profile?
        let comparison: Comparison?
    }

    static func run(_ arguments: [String]) throws -> Data {
        let options = try Options(arguments)
        let url = URL(fileURLWithPath: options.path)
        let limits = LegacyLanguageReadLimits()
        let before = try fingerprint(url, maximum: limits.maximumFileBytes)
        let data = try LegacyLanguageProfileReader.read(url: url, limits: limits)
        let selected: LegacyLanguageProfile?
        if let identifier = options.profile { selected = try data.profile(languageIdentifier: identifier) }
        else { selected = nil }
        let comparison: Comparison?
        if let operands = options.operands, let selected {
            let context = try LegacyWeightedComparisonContext(profile: selected,
                collation: data.collation(identifier: selected.collationIdentifier))
            let left = Array(operands.0.utf16), right = Array(operands.1.utf16)
            comparison = .init(leftUnitCount: left.count, rightUnitCount: right.count,
                               ordering: try context.compare(left, right))
        } else { comparison = nil }
        guard try fingerprint(url, maximum: limits.maximumFileBytes) == before else {
            throw LegacyIndicesError.sourceChanged
        }
        let evidence = Evidence(sourceVerifiedAfter: true, source: before, directoryRecordCount: data.directoryRecordCount,
            profiles: data.profiles.map(Profile.init), collations: data.collations.map(Collation.init),
            selectedProfile: selected.map(Profile.init), comparison: comparison)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(evidence)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprint(_ url: URL, maximum: Int) throws -> Source {
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        var digest = SHA256(), count = 0
        while let bytes = try stream.read(upToCount: 64 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            guard bytes.count <= maximum - count else { throw LegacyLanguageError.limitExceeded }
            count += bytes.count; digest.update(data: bytes)
        }
        return Source(name: url.lastPathComponent, byteCount: count,
                      sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
