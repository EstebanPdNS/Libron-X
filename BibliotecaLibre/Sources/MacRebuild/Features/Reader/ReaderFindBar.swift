import SwiftUI

struct ReaderFindBar: View {
    @Bindable var reader: ReaderSession
    var activate: () -> Void = {}
    @FocusState private var fieldFocused: Bool
    var body: some View {
        HStack(spacing: 8) {
            MacToolbarLabel(L("Buscar"), "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Buscar en este recurso"), text: Binding(get: { reader.findQuery }, set: reader.updateFindQuery))
                .macInputStyle().focused($fieldFocused)
                .foregroundStyle(reader.findStatus == .notFound ? Color.red : Color.primary)
                .onSubmit { activate(); reader.find(.forward) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    activate(); reader.find(.backward); return .handled
                }
                .onExitCommand { reader.hideFind() }
                .accessibilityLabel(L("Buscar en este recurso"))
            Button { activate(); reader.find(.backward) } label: { MacToolbarLabel(L("Coincidencia anterior"), "chevron.up") }
                .help(L("Coincidencia anterior (⇧⌘G)")).accessibilityLabel(L("Coincidencia anterior"))
                .disabled(reader.findQuery.isEmpty || reader.page == nil)
            Button { activate(); reader.find(.forward) } label: { MacToolbarLabel(L("Coincidencia siguiente"), "chevron.down") }
                .help(L("Coincidencia siguiente (⌘G)")).accessibilityLabel(L("Coincidencia siguiente"))
                .disabled(reader.findQuery.isEmpty || reader.page == nil)
            Menu {
                option("Distinguir mayúsculas", \.caseSensitive)
                option("Distinguir acentos", \.diacriticSensitive)
                option("Palabras completas", \.wholeWords)
                Divider()
                option("Continuar desde el inicio o el final", \.wraps)
            } label: { MacToolbarLabel(L("Opciones de búsqueda"), "slider.horizontal.3") }.help(L("Opciones de búsqueda")).menuIndicator(.hidden)
            status
            Button { reader.hideFind() } label: { MacToolbarLabel(L("Cerrar búsqueda"), "xmark") }
                .help(L("Cerrar búsqueda (Esc)")).accessibilityLabel(L("Cerrar búsqueda"))
        }.modifier(MacPanelControlPresentation()).padding(7).background(.bar)
            .onChange(of: reader.findFocusRequest, initial: true) { fieldFocused = true }
            .onChange(of: fieldFocused) { if fieldFocused { activate() } }
    }
    private func option(_ title: String, _ key: WritableKeyPath<ReaderFindOptions, Bool>) -> some View {
        Toggle(L(title), isOn: Binding(get: { reader.findOptions[keyPath: key] }, set: { value in
            activate(); var options = reader.findOptions; options[keyPath: key] = value; reader.updateFindOptions(options)
        }))
    }
    @ViewBuilder private var status: some View {
        switch reader.findStatus {
        case .searching:
            ProgressView().controlSize(.small)
            Button(L("Cancelar"), action: reader.cancelFind)
        case .notFound: Text(L("Sin coincidencias")).font(.caption).foregroundStyle(.red)
        case .failed(let message): MacToolbarLabel(L("Error de búsqueda"), "exclamationmark.triangle").foregroundStyle(.orange).help(message)
        case .found(let wrapped):
            if wrapped { MacToolbarLabel(L("Búsqueda desde el otro extremo"), "arrow.uturn.down").help(L("La búsqueda continuó desde el otro extremo del recurso.")) }
        case .idle: EmptyView()
        }
    }
}
