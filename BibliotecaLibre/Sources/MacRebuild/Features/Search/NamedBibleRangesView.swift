import SwiftUI
import LibronixCore

struct NamedBibleRangesView: View {
    @Bindable var personal: WorkspacePersonalState
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var name = ""
    @RebuildViewState private var expression = ""
    @RebuildViewState private var deleting = false
    @RebuildViewState private var error: String?
    private var selected: NamedBibleSearchRange? { personal.namedBibleRanges.ranges.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Rangos guardados") { dismiss() }
            List(personal.namedBibleRanges.ranges, selection: $selectedID) { range in Text(range.name).tag(range.id) }
                .overlay { if personal.namedBibleRanges.ranges.isEmpty { Text(L("No hay rangos guardados.")).foregroundStyle(.secondary).allowsHitTesting(false) } }
            TextField(L("Nombre del rango"), text: $name).macInputStyle()
            TextField(L("Pasajes, por ejemplo Gn 1–3; Juan 3:16–18; Romanos"), text: $expression).macInputStyle()
            if let message = error ?? personal.namedBibleRangesLoadError { Text(L(message)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(L("Añadir rango")) { save(add: true) }
                Button(L("Actualizar rango")) { save(add: false) }.disabled(selected == nil)
                Button(L("Eliminar rango")) { deleting = true }.disabled(selected == nil)
                Spacer()
            }
        }.padding(16).frame(width: 600, height: 480).modifier(MacPanelControlPresentation())
            .onChange(of: selectedID) { name = selected?.name ?? ""; expression = selected?.expression ?? "" }
            .alert(L("Eliminar rango"), isPresented: $deleting) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Eliminar"), role: .destructive) { remove() }
            } message: { Text(L("Se eliminará este rango guardado.")) }
    }
    private func save(add: Bool) {
        let original = add ? nil : selected
        if !add && original == nil { return }
        var value = original ?? NamedBibleSearchRange(name: name, expression: expression)
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try personal.editNamedBibleRanges { state in
                if let original {
                    guard let index = state.ranges.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                    state.ranges[index] = value
                } else { state.ranges.append(value) }
            }
            selectedID = value.id; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func remove() {
        guard let original = selected else { return }
        do {
            try personal.editNamedBibleRanges { state in
                guard let index = state.ranges.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                state.ranges.remove(at: index)
            }
            selectedID = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
