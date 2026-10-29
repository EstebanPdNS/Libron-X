import AppKit
import CoreText

extension NSAttributedString.Key {
    static let readerListLabel = Self("org.libronx.reader.listLabel")
    static let readerCapitalizedGlyph = Self("org.libronx.reader.capitalizedGlyph")
    static let readerMarkOutline = Self("org.libronx.reader.markOutline")
}

/// Draws source labels outside body coordinates and substitutes one-to-one
/// capitalized glyphs. The text storage, copied text and search offsets do not change.
final class ReaderLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() { super.init(); delegate = self }
    required init?(coder: NSCoder) { super.init(coder: coder); delegate = self }
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.readerMarkOutline, in: characters) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let visible = NSIntersectionRange(glyphs, glyphsToShow)
            guard visible.length > 0, let container = textContainer(forGlyphAt: visible.location, effectiveRange: nil) else { return }
            color.setStroke()
            enumerateEnclosingRects(forGlyphRange: visible, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let outline = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: 1)
                guard outline.width > 0, outline.height > 0 else { return }
                let path = NSBezierPath(roundedRect: outline, xRadius: 3, yRadius: 3)
                path.lineWidth = 1.5; path.stroke()
            }
        }
    }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }
        var generated = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length)), changed = false
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        for index in 0..<glyphRange.length {
            let character = charIndexes[index]
            if character < storage.length,
               let unit = storage.attribute(.readerInterlinearUnit, at: character, effectiveRange: nil) as? ReaderInterlinearGlyph {
                generated[index] = 0
                properties[index] = character == unit.sourceRange.location ? .controlCharacter : .null
                changed = true; continue
            }
            guard character < storage.length,
                  let number = storage.attribute(.readerCapitalizedGlyph, at: character, effectiveRange: nil) as? NSNumber else { continue }
            var upper = number.uint16Value, glyph: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(aFont as CTFont, &upper, &glyph, 1), glyph != 0 {
                generated[index] = glyph; changed = true
            }
        }
        guard changed else { return 0 }
        generated.withUnsafeBufferPointer { pointer in
            properties.withUnsafeBufferPointer { properties in
                setGlyphs(pointer.baseAddress!, properties: properties.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            }
        }
        return glyphRange.length
    }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt character: Int) -> NSLayoutManager.ControlCharacterAction {
        if let unit = textStorage?.attribute(.readerInterlinearUnit, at: character, effectiveRange: nil) as? ReaderInterlinearGlyph {
            return character == unit.sourceRange.location ? .whitespace : .zeroAdvancement
        }
        return action
    }
    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyph: Int,
                       for container: NSTextContainer, proposedLineFragment: NSRect,
                       glyphPosition: NSPoint, characterIndex: Int) -> NSRect {
        guard let unit = textStorage?.attribute(.readerInterlinearUnit, at: characterIndex, effectiveRange: nil) as? ReaderInterlinearGlyph else { return .zero }
        return NSRect(origin: .zero, size: unit.size)
    }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect fragment: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect used: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in container: NSTextContainer, forGlyphRange range: NSRange) -> Bool {
        guard let storage = textStorage else { return false }
        var height: CGFloat = 0
        let characters = characterRange(forGlyphRange: range, actualGlyphRange: nil)
        storage.enumerateAttribute(.readerInterlinearUnit, in: characters) { value, _, _ in
            if let unit = value as? ReaderInterlinearGlyph { height = max(height, unit.size.height) }
        }
        guard height > 0 else { return false }
        fragment.pointee.size.height = max(fragment.pointee.height, height)
        used.pointee.size.height = max(used.pointee.height, height)
        return true
    }
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.readerInterlinearUnit, in: characters) { value, range, _ in
            guard let unit = value as? ReaderInterlinearGlyph,
                  NSLocationInRange(unit.sourceRange.location, characters) else { return }
            let glyph = glyphIndexForCharacter(at: unit.sourceRange.location)
            guard NSLocationInRange(glyph, glyphsToShow) else { return }
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil), location = location(forGlyphAt: glyph)
            unit.draw(at: NSPoint(x: origin.x + fragment.minX + location.x, y: origin.y + fragment.minY))
        }
        storage.enumerateAttribute(.readerListLabel, in: characters) { value, range, _ in
            guard let label = value as? String, !label.isEmpty else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            guard NSLocationInRange(glyph, glyphsToShow),
                  let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: font,
                .foregroundColor: storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) ?? NSColor.textColor]
            let text = NSAttributedString(string: label, attributes: attributes)
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil), location = location(forGlyphAt: glyph)
            text.draw(at: NSPoint(x: origin.x + fragment.minX + location.x - text.size().width - font.pointSize * 0.35,
                                  y: origin.y + fragment.minY + location.y - font.ascender))
        }
    }
}
