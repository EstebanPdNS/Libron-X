import AppKit
import LibronixCore

/// One hyperlink presentation for continuous reading, notes and HTML resources.
/// Source ranges and destinations are retained. A link covering a complete
/// Bible verse receives this presentation on its leading number only.
@MainActor enum ReaderSourceLinkAttributes {
    static let htmlScript = #"""
    (() => {
      const style = document.createElement('style');
      style.id = 'libron-reader-links';
      style.textContent = 'a[href],a[href]:visited,a[href] *{color:rgb(0,104,218)!important;text-decoration-line:underline!important;text-decoration-color:currentColor!important;text-underline-offset:0.12em;cursor:pointer}';
      document.head.appendChild(style);
    })();
    """#

    static func install(_ links: [LegacyInlineLink], in display: NSMutableAttributedString,
                        verseAnchors: [LegacyReferenceAnchor] = []) {
        let text = display.string as NSString
        let verses = ReaderBibleIndex(anchors: verseAnchors, textLength: text.length).entries
        let bodies: [NSRange] = verses.enumerated().compactMap { index, verse in
            let end = index + 1 < verses.count ? verses[index + 1].offset : text.length
            guard end > verse.offset else { return nil }
            let original = text.substring(with: NSRange(location: verse.offset, length: end - verse.offset)) as NSString
            let number = original.range(of: #"^\s*[0-9]+\s+"#, options: .regularExpression)
            let start = number.location == 0 ? NSMaxRange(number) : 0
            let body = original.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            let range = original.range(of: body, options: .literal, range: NSRange(location: start, length: original.length - start))
            return NSRange(location: verse.offset + range.location, length: range.length)
        }
        for (index, link) in links.enumerated() where Range(link.range, in: display.string) != nil {
            guard let url = URL(string: "libronx-inline://local/\(index)") else { continue }
            display.addAttribute(.link, value: url, range: link.range)
            let source = text.substring(with: link.range)
            let marker = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !marker.isEmpty, !marker.contains("\u{fffc}") else { continue }
            var local = (source as NSString).range(of: marker)
            if bodies.contains(where: { $0.length > 8 && NSIntersectionRange($0, link.range).length == $0.length }) {
                display.removeAttribute(.underlineStyle, range: link.range)
                local = (source as NSString).range(of: #"^\s*[0-9]+(?=\s|$)"#, options: .regularExpression)
                guard local.location != NSNotFound else { continue }
                let number = (source as NSString).substring(with: local).trimmingCharacters(in: .whitespacesAndNewlines)
                local = (source as NSString).range(of: number, options: .literal, range: local)
            }
            let markerRange = NSRange(location: link.range.location + local.location, length: local.length)
            display.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.linkColor, .foregroundColor: NSColor.linkColor,
                .toolTip: LF("Nota o referencia {label}", ["label": marker])], range: markerRange)
        }
    }
}
