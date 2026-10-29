import SwiftUI
import AppKit
import LibronixCore

enum TransliterationLanguage: String, CaseIterable { case greek, hebrew }
enum TransliterationInput {
    static let maximumUTF16 = 4_096
    static func convert(_ text: String, language: TransliterationLanguage) -> String? {
        guard text.utf16.count <= maximumUTF16, !text.contains("\0") else { return nil }
        switch language {
        case .greek: return BibleCopyTransliterator.greekSBL(text)
        case .hebrew: return BibleCopyTransliterator.hebrewLogos(text)
        }
    }
}
struct TransliterationView: View {
    @RebuildViewState private var input = ""
    @RebuildViewState private var language = TransliterationLanguage.greek
    private var output: String? { TransliterationInput.convert(input, language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("Idioma de origen"), selection: $language) {
                Text(L("Griego")).tag(TransliterationLanguage.greek)
                Text(L("Hebreo")).tag(TransliterationLanguage.hebrew)
            }
            Text(L("Texto original"))
            TextEditor(text: $input).scrollContentBackground(.hidden).padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
                .accessibilityLabel(L("Texto original"))
            Text(L("Transliteración"))
            ScrollView {
                Text(output ?? L("El texto supera el límite permitido."))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(12)
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
            Text(L("La conversión es una aproximación; el texto original se conserva sin cambios."))
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L("Copiar")) {
                guard let output, !output.isEmpty else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string)
            }.disabled(output?.isEmpty != false) }
        }.padding(16)
    }
}
