import SwiftUI

struct WorkspaceSearchMatchingPicker: View {
    @Bindable var search: WorkspaceSearchController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(L("Coincidencia"), selection: $search.approximatePhrase) {
                    Text(L("Exacta")).tag(false)
                    Text(L("Frase aproximada")).tag(true)
                }
                if search.approximatePhrase {
                    Picker(L("Cambios máximos"), selection: $search.maximumEdits) {
                        ForEach(1...3, id: \.self) { Text(verbatim: String($0)).tag($0) }
                    }
                }
            }
            if search.approximatePhrase {
                Text(L("Frase literal, sin operadores: inserciones, eliminaciones o sustituciones de caracteres. No reordena palabras."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("Máximo 256 caracteres; la frase debe ser más larga que el límite de cambios. Los límites de trabajo producen cobertura parcial."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
