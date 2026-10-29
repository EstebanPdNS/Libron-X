import AppKit

enum ReaderMarkPresentation {
    static func apply(_ mark: ReaderHighlight, to text: NSMutableAttributedString) {
        guard mark.range.location >= 0, mark.range.length > 0,
              mark.range.location <= text.length, mark.range.length <= text.length - mark.range.location else { return }
        let color: NSColor = switch mark.color { case "green": .systemGreen; case "blue": .systemBlue; case "pink": .systemPink; default: .systemYellow }
        switch mark.style {
        case .underline:
            text.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: color], range: mark.range)
        case .strike:
            text.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: color], range: mark.range)
        case nil:
            text.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.35), range: mark.range)
        }
    }
}
