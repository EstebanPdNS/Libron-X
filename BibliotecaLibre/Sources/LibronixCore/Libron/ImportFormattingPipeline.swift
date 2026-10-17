import Foundation

/// Deterministic presentation repairs never rewrite the immutable source file.
public enum ImportFormattingPipeline {
    public static let version = 1
    public struct HTMLResult: Sendable {
        public var html: String
        public var removedActiveSurfaces: Int
    }
    public struct TextResult: Sendable {
        public var text: String
        public var repairedCharacters: Int
        public init(text: String, repairedCharacters: Int) {
            self.text = text; self.repairedCharacters = repairedCharacters
        }
    }
    public static func html(_ source: String) -> HTMLResult {
        var html = source, removed = 0
        let patterns = [
            #"(?is)<(script|iframe|object|embed|video|audio|svg|math)\b[^>]*>.*?</\1\s*>"#,
            #"(?is)<(?:img|link|base|meta|input|form)\b[^>]*>"#,
            #"(?is)\sstyle\s*=\s*(?:"[^"]*(?:url\s*\(|@import|expression\s*\()[^"]*"|'[^']*(?:url\s*\(|@import|expression\s*\()[^']*')"#,
            #"(?is)\s(?:src|srcset|background|on[a-z]+)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            removed += regex.numberOfMatches(in: html, range: range)
            html = regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        }
        // Safe stylesheet rules remain available to the native HTML parser.
        for pattern in [#"(?is)@import\s+[^;]+;?"#, #"(?is)url\s*\([^)]*\)"#, #"(?is)expression\s*\([^)]*\)"#] {
            html = html.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // AppKit owns entity decoding and malformed-HTML recovery. Semantic
        // elements, inline styles, tables, lists, direction and links survive.
        return .init(html: "<html><head><meta charset='UTF-8'></head><body>" + html + "</body></html>", removedActiveSurfaces: removed)
    }
    /// A legacy e-Sword export occasionally substitutes single Greek/Hebrew/PUA
    /// glyphs inside otherwise Latin words. Only observed one-to-one mappings
    /// in Latin-majority words qualify; genuine Greek/Hebrew words are retained.
    public static func repairLegacyCharacters(_ source: String) -> TextResult {
        let mappings: [Unicode.Scalar: Unicode.Scalar] = ["σ":"ó", "α":"á", "ב":"á", "ם":"í", "ת":"ú", "ף":"ó", "\u{F88E}":"Ú"]
        guard source.unicodeScalars.contains(where: { mappings[$0] != nil }),
              let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{M}\p{Co}]+"#) else { return .init(text: source, repairedCharacters: 0) }
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var result = source, count = 0
        for match in matches.reversed() {
            guard let range = Range(match.range, in: source) else { continue }
            let word = String(source[range])
            let foreign = word.unicodeScalars.filter { mappings[$0] != nil }
            let latin = word.unicodeScalars.filter { scalar in
                (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122) ||
                (scalar.value >= 0x00C0 && scalar.value <= 0x024F)
            }.count
            guard !foreign.isEmpty, latin >= 3, foreign.count * 3 <= latin,
                  word.unicodeScalars.allSatisfy({ scalar in
                      mappings[scalar] != nil || (scalar.value <= 0x024F && CharacterSet.letters.contains(scalar)) || CharacterSet.nonBaseCharacters.contains(scalar)
                  }) else { continue }
            let repaired = String(String.UnicodeScalarView(word.unicodeScalars.map { mappings[$0] ?? $0 }))
            // Every replacement has one UTF-16 unit, preserving all rich-text
            // ranges, verse anchors and paragraph boundaries in the projection.
            guard repaired.utf16.count == word.utf16.count, let outputRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(outputRange, with: repaired); count += foreign.count
        }
        return .init(text: result, repairedCharacters: count)
    }
}
