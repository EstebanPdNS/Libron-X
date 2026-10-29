import SwiftUI
import LibronixCore

extension MarkColor {
    var color: Color {
        switch self { case .yellow: .yellow; case .green: .green; case .blue: .blue; case .pink: .pink }
    }
    var title: String {
        switch self { case .yellow: "Amarillo"; case .green: "Verde"; case .blue: "Azul"; case .pink: "Rosa" }
    }
}

struct MarkPalettesView: View {
    private enum PendingAction { case close, select(UUID?) }
    @Bindable var personal: WorkspacePersonalState
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var selected: UUID?
    @RebuildViewState private var name = ""
    @RebuildViewState private var colors: Set<MarkColor> = Set(MarkColor.allCases)
    @RebuildViewState private var deleting = false
    @RebuildViewState private var error: String?
    @RebuildViewState private var pendingAction: PendingAction?
    @RebuildViewState private var confirmsDiscard = false
    private var palette: MarkPalette? { personal.markPalettes.palettes.first { $0.id == selected } }
    private var hasDraft: Bool {
        if let palette { return name != palette.name || colors != Set(palette.colors) }
        return !name.isEmpty || colors != Set(MarkColor.allCases)
    }
    private var selection: Binding<UUID?> {
        Binding(get: { selected }, set: { next in
            guard next != selected else { return }
            if hasDraft { pendingAction = .select(next); confirmsDiscard = true }
            else { selected = next }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Paletas de marcación") { requestClose() }
            List(personal.markPalettes.palettes, selection: selection) { palette in Text(palette.name).tag(palette.id) }
                .overlay { if personal.markPalettes.palettes.isEmpty { Text(L("No hay paletas guardadas.")).foregroundStyle(.secondary) } }
            TextField(L("Nombre de la paleta"), text: $name).macInputStyle()
            Text(L("Colores"))
            HStack {
                ForEach(MarkColor.allCases, id: \.self) { color in
                    Toggle(L(color.title), isOn: Binding(get: { colors.contains(color) }, set: { enabled in
                        if enabled { colors.insert(color) } else { colors.remove(color) }
                    }))
                }
            }
            if let message = error ?? personal.markPalettesLoadError { Text(L(message)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(L("Añadir paleta")) { save(new: true) }
                Button(L("Actualizar paleta")) { save(new: false) }.disabled(palette == nil)
                Button(L("Eliminar paleta")) { deleting = true }.disabled(palette == nil)
                Spacer()
            }
        }.padding(16).frame(width: 600, height: 430).modifier(MacPanelControlPresentation())
            .onChange(of: selected) { name = palette?.name ?? ""; colors = Set(palette?.colors ?? MarkColor.allCases) }
            .interactiveDismissDisabled()
            .onExitCommand(perform: requestClose)
            .alert(L("Cambios sin guardar"), isPresented: $confirmsDiscard) {
                Button(L("Cancelar"), role: .cancel) { pendingAction = nil }
                Button(L("Descartar"), role: .destructive) { finishPending() }
                Button(L("Guardar")) { if save(new: palette == nil) { finishPending() } }
            } message: { Text(L("Guarda la paleta antes de continuar.")) }
            .alert(L("Eliminar paleta"), isPresented: $deleting) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Eliminar"), role: .destructive) { remove() }
            } message: { Text(L("Se eliminará esta paleta de marcación.")) }
    }
    @discardableResult private func save(new: Bool) -> Bool {
        let original = new ? nil : palette
        if !new && original == nil { return false }
        var value = original ?? MarkPalette(name: name, colors: [])
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.colors = MarkColor.allCases.filter(colors.contains)
        do {
            try personal.editMarkPalettes { state in
                if let original {
                    guard let index = state.palettes.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                    state.palettes[index] = value
                } else { state.palettes.append(value) }
            }
            selected = value.id; error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func remove() {
        guard let original = palette else { return }
        do {
            try personal.editMarkPalettes { state in
                guard let index = state.palettes.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                state.palettes.remove(at: index)
                if state.selectedID == original.id { state.selectedID = nil }
            }
            selected = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func requestClose() {
        if hasDraft { pendingAction = .close; confirmsDiscard = true } else { dismiss() }
    }
    private func finishPending() {
        let action = pendingAction; pendingAction = nil
        switch action { case .close: dismiss(); case .select(let next): selected = next; case nil: break }
    }
}
