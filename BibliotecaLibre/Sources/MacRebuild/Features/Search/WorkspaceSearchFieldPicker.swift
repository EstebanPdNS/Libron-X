import SwiftUI
import LibronixCore

@MainActor extension SearchField {
    var localizedTitle: String {
        switch self {
        case .title: L("Título")
        case .body: L("Cuerpo")
        case .footnote: L("Notas al pie")
        case .heading: L("Encabezados")
        case .bibleText: L("Texto bíblico")
        case .quotation: L("Citas")
        }
    }
}
struct WorkspaceSearchFieldPicker: View {
    @Binding var field: SearchField?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Campo")).font(.caption).foregroundStyle(.secondary)
            MacSelectionMenu(L("Campo"), value: field?.localizedTitle ?? L("Todo el texto"), selection: $field) {
                Text(L("Todo el texto")).tag(Optional<SearchField>.none)
                ForEach(SearchField.allCases, id: \.self) { Text($0.localizedTitle).tag(Optional($0)) }
            }
            Text(L("Los campos no identificados por el recurso producen cobertura parcial.")).font(.caption).foregroundStyle(.secondary)
            if field == .title {
                Text(L("Un título del índice puede abrir su artículo sin resaltar el cuerpo.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
