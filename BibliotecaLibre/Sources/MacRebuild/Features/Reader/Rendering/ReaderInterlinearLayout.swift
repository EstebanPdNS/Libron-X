import AppKit
import LibronixCore

extension NSAttributedString.Key {
    static let readerInterlinearUnit = Self("org.libronx.reader.interlinearUnit")
}

/// A TextKit control glyph reserves one source word's aligned multiline box.
/// The backing text remains the complete surface line; no annotation string is
/// inserted into article coordinates or substituted for the source word.
final class ReaderInterlinearGlyph: NSObject {
    let sourceRange: NSRange
    let rows: [NSAttributedString]
    let rowHeights: [CGFloat]
    let padding: CGFloat
    let size: NSSize
    init(range: NSRange, rows: [NSAttributedString], rowHeights: [CGFloat], scale: Double) {
        sourceRange = range; self.rows = rows; self.rowHeights = rowHeights; padding = 3 * scale
        size = NSSize(width: max(1, rows.map { ceil($0.size().width) }.max() ?? 1) + padding * 2,
                      height: rowHeights.reduce(0,+) + padding * 2)
    }
    func draw(at point: NSPoint) {
        var y = point.y + padding
        for (index, row) in rows.enumerated() {
            row.draw(in: NSRect(x: point.x + padding, y: y, width: size.width - padding * 2, height: rowHeights[index]))
            y += rowHeights[index]
        }
    }
    func rebased(to range: NSRange) -> ReaderInterlinearGlyph {
        ReaderInterlinearGlyph(range: range, rows: rows, rowHeights: rowHeights, scale: padding / 3)
    }
}

@MainActor enum ReaderInterlinearLayout {
    static func apply(_ units: [LegacyInterlinearRun], to text: NSMutableAttributedString,
                      typography: LegacyTypography, scale: Double, visibleLines: Set<Int>?, warnings: inout Set<String>) {
        guard !units.isEmpty else { return }
        struct Prepared { let unit: LegacyInterlinearRun; let rows: [(Int, NSAttributedString)] }
        var prepared: [Prepared] = [], metrics: [Int: CGFloat] = [:]
        var attributeCache: [UInt16: [NSAttributedString.Key: Any]] = [:]
        for unit in units {
            let span = NSRange(location: unit.surfaceCharacterOffset, length: unit.surfaceText.utf16.count)
            guard span.length > 0, span.location >= 0, NSMaxRange(span) <= text.length,
                  (text.string as NSString).substring(with: span) == unit.surfaceText else {
                warnings.insert("Una unidad interlineal sin texto de superficie necesita su disposición específica."); continue
            }
            var rows: [(Int, NSAttributedString)] = []
            for line in unit.lines where visibleLines?.contains(line.ordinal) ?? true {
                let display = NSMutableAttributedString(string: line.text, attributes: [
                    .font: NSFont(name: "Times New Roman", size: 12 * scale) ?? NSFont.systemFont(ofSize: 12 * scale),
                    .foregroundColor: NSColor.textColor])
                var height: CGFloat = 14 * scale
                for run in line.runs {
                    let range = NSRange(location: run.characterOffset, length: run.logicalCharacterCount)
                    guard range.location >= 0, NSMaxRange(range) <= display.length,
                          let style = typography.characterStyle(run.styleIdentifier) else { continue }
                    let attributes: [NSAttributedString.Key: Any]
                    if let cached = attributeCache[run.styleIdentifier] { attributes = cached }
                    else {
                        attributes = ReaderTypography.characterAttributes(style, typography: typography, scale: scale, warnings: &warnings)
                        attributeCache[run.styleIdentifier] = attributes
                    }
                    display.addAttributes(attributes, range: range)
                    if let font = attributes[.font] as? NSFont { height = max(height, ceil(font.ascender - font.descender + font.leading)) }
                }
                if line.runs.contains(where: { $0.localeIdentifier == 1037 || $0.localeIdentifier == 1728 }) {
                    let paragraph = NSMutableParagraphStyle(); paragraph.baseWritingDirection = .rightToLeft
                    paragraph.alignment = .left
                    display.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: display.length))
                }
                metrics[line.ordinal] = max(metrics[line.ordinal] ?? 0, height + 2 * scale)
                rows.append((line.ordinal, display))
            }
            if !rows.isEmpty { prepared.append(.init(unit: unit, rows: rows)) }
        }
        for item in prepared {
            let range = NSRange(location: item.unit.surfaceCharacterOffset, length: item.unit.surfaceText.utf16.count)
            let glyph = ReaderInterlinearGlyph(range: range, rows: item.rows.map(\.1),
                rowHeights: item.rows.map { metrics[$0.0]! }, scale: scale)
            text.addAttribute(.readerInterlinearUnit, value: glyph, range: range)
        }
    }
}
