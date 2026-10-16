import Foundation

public struct LegacyLocatorResolution: Sendable, Equatable {
    public let location: ReaderLocation
    public let range: SearchTextRange
    public let sourceCharacterCount: UInt32

    static func checkContext(_ values: [String: String], text: String, range: SearchTextRange) throws {
        guard contextChecks(values, text: text, range: range).values.allSatisfy({ $0 }) else { throw LegacyLocatorError.contextMismatch }
    }
    public static func contextChecks(_ values: [String: String], text: String, range: SearchTextRange) -> [String: Bool] {
        let count = text.utf16.count
        guard range.location >= 0, range.length >= 0, range.location <= count, range.length <= count - range.location else { return ["range": false] }
        var checks: [String: Bool] = [:]
        for key in ["start-article-length", "end-article-length"] {
            if let value = values[key] {
                checks[key] = Int(value) == count
            }
        }
        // This policy is the scoped pattern measured in the original RVR60
        // selection fixture: left context ends at the selection end; right
        // context begins at its start. Both include the selected text. The
        // length attributes count surrounding context, excluding selection.
        // The shipped writer at 0x141caaae changes U+200B to U+FEFF one unit
        // at a time. Apply that verified projection only to hint comparison;
        // decoded text, source hashes and all offsets remain unchanged.
        let source = text.replacingOccurrences(of: "\u{200b}", with: "\u{feff}") as NSString
        if let raw = values["start-hint"] {
            guard let hint = raw.removingPercentEncoding, hint.utf16.count <= range.upperBound else { checks["start-hint"] = false; return checks }
            if let rawLength = values["start-hint-length"] {
                checks["start-hint-length"] = Int(rawLength).map { $0 >= 0 && hint.utf16.count == min($0, range.location) + range.length } ?? false
            }
            let part = source.substring(with: NSRange(location: range.upperBound - hint.utf16.count, length: hint.utf16.count))
            checks["start-hint"] = part.utf16.elementsEqual(hint.utf16)
        }
        if let raw = values["end-hint"] {
            guard let hint = raw.removingPercentEncoding, hint.utf16.count <= count - range.location else { checks["end-hint"] = false; return checks }
            if let rawLength = values["end-hint-length"] {
                checks["end-hint-length"] = Int(rawLength).map { $0 >= 0 && hint.utf16.count == min($0, count - range.upperBound) + range.length } ?? false
            }
            let part = source.substring(with: NSRange(location: range.location, length: hint.utf16.count))
            checks["end-hint"] = part.utf16.elementsEqual(hint.utf16)
        }
        return checks
    }
    public static func contextFields(_ source: String) -> [String: String] {
        var result: [String: String] = [:]
        for field in source.split(separator: "|", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        return result
    }
}
