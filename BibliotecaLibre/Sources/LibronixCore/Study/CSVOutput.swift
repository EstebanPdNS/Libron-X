import Foundation

/// RFC 4180 output for user-authored or source-authored text. Spreadsheet
/// formula prefixes are escaped without removing whitespace or source content.
public enum CSVOutput {
    public static func row(_ cells: [String]) -> String {
        cells.map { value in
            let leading = value.trimmingCharacters(in: .whitespacesAndNewlines).first
            let formula = leading.map { "=+-@".contains($0) } ?? false
            let control = value.first.map { "\t\r\n".contains($0) } ?? false
            return "\"" + (formula || control ? "'" : "")
                + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") + "\r\n"
    }
}
