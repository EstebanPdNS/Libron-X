import AppKit
import NaturalLanguage
import SwiftUI

/// Literal study content follows its own writing direction, independently of
/// the translated interface labels and action groups around it.
struct MacSourceText: View {
    let text: String
    var body: some View {
        let language = NLLanguageRecognizer.dominantLanguage(for: String(text.prefix(1024)))?.rawValue
        Text(verbatim: text).frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, NSParagraphStyle.defaultWritingDirection(forLanguage: language) == .rightToLeft ? .rightToLeft : .leftToRight)
    }
}
