import SwiftUI
import LibronixCore

struct LibraryCollectionRuleEditor: View {
    @Binding var rule: LibraryCollectionRule
    let savedRule: LibraryCollectionRule
    let resources: [LibraryResource]
    let save: () -> Void
    private var validationError: String? {
        do { try rule.validate(); return nil } catch { return error.localizedDescription }
    }
    private var matches: [LibraryResource] {
        guard validationError == nil else { return [] }
        return resources.filter(rule.matches).sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("La pertenencia se actualiza al cambiar los metadatos de la biblioteca. No se modifica ningún libro."))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L("Coincidencia"), selection: $rule.match) {
                ForEach(LibraryCollectionRule.Match.allCases, id: \.self) { Text($0.title).tag($0) }
            }.fixedSize()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($rule.conditions) { $condition in
                        HStack {
                            Picker(L("Campo"), selection: $condition.field) {
                                ForEach(LibraryCollectionRule.Field.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(width: 125)
                            Picker(L("Condición"), selection: $condition.operation) {
                                ForEach(LibraryCollectionRule.Operation.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(width: 130)
                            TextField(L("Valor"), text: $condition.value).macInputStyle()
                                .disabled(!condition.operation.needsValue)
                            Button(L("Quitar condición"), systemImage: "minus.circle") {
                                rule.conditions.removeAll { $0.id == condition.id }
                            }.labelStyle(.iconOnly).disabled(rule.conditions.count <= 1)
                        }
                    }
                }.padding(2)
            }.frame(height: 150)
            HStack {
                Button(L("Agregar condición"), systemImage: "plus.circle") { rule.conditions.append(.init()) }
                    .disabled(rule.conditions.count >= 32)
                Spacer()
                Button(L("Restablecer")) { rule = savedRule }.disabled(rule == savedRule)
                Button(L("Guardar reglas"), action: save).disabled(validationError != nil || rule == savedRule)
            }
            if let validationError { Text(validationError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text(L("Vista previa")).font(.headline)
            Text(LF("{count} recursos", ["count": String(matches.count)])).font(.caption)
            if rule != savedRule { Text(L("Cambios sin guardar")).font(.caption).foregroundStyle(.secondary) }
            List(matches) { resource in
                VStack(alignment: .leading) {
                    Text(resource.title).lineLimit(1)
                    Text(resource.location.lastPathComponent + " · " + resource.format.displayName).font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityLabel(L("Vista previa de la colección"))
        }
    }
}
