import SwiftUI
import AppKit
import LibronixCore
import Observation

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
    static func literalQuery(_ text: String) -> SearchQuery? {
        guard !text.contains("\0"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return try? SearchQueryParser.parse("\"" + escaped + "\"")
    }
}
@MainActor @Observable final class TransliterationController {
    var input = ""
    var language = TransliterationLanguage.greek
    var output: String? { TransliterationInput.convert(input, language: language) }
    var originalQuery: SearchQuery? { TransliterationInput.literalQuery(input) }
    var convertedQuery: SearchQuery? { output.flatMap(TransliterationInput.literalQuery) }
    func prepareSearch(_ query: SearchQuery, in search: WorkspaceSearchController) -> Bool {
        guard !search.isSearching else { return false }
        search.clear()
        search.query = query.source
        search.searchField = nil; search.wordFilter = nil; search.approximatePhrase = false
        search.bibleVerses = false; search.wholeWords = false
        return true
    }
}
struct TransliterationView: View {
    @Bindable var controller: TransliterationController
    @Bindable var search: WorkspaceSearchController
    let showSearch: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("Idioma de origen"), selection: $controller.language) {
                Text(L("Griego")).tag(TransliterationLanguage.greek)
                Text(L("Hebreo")).tag(TransliterationLanguage.hebrew)
            }
            Text(L("Texto original"))
            TextEditor(text: $controller.input).scrollContentBackground(.hidden).padding(8)
                .macEditorSurface()
                .accessibilityLabel(L("Texto original"))
            Text(L("Transliteración"))
            ScrollView {
                Text(controller.output ?? L("El texto supera el límite permitido."))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(12)
            }.macEditorSurface()
            Text(L("La conversión es una aproximación; el texto original se conserva sin cambios."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("La búsqueda usa una frase literal de hasta 512 caracteres UTF-16; no convierte el contenido de los libros."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Menu {
                    Button(L("Buscar texto original")) {
                        if let query = controller.originalQuery, controller.prepareSearch(query, in: search) { showSearch() }
                    }.disabled(controller.originalQuery == nil)
                    Button(L("Buscar transliteración")) {
                        if let query = controller.convertedQuery, controller.prepareSearch(query, in: search) { showSearch() }
                    }.disabled(controller.convertedQuery == nil)
                } label: { Label(L("Usar en búsqueda"), systemImage: "magnifyingglass") }
                    .disabled(search.isSearching || (controller.originalQuery == nil && controller.convertedQuery == nil))
                Spacer()
                Button(L("Copiar")) {
                guard let output = controller.output, !output.isEmpty else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string)
            }.disabled(controller.output?.isEmpty != false) }
        }.padding(16)
    }
}
