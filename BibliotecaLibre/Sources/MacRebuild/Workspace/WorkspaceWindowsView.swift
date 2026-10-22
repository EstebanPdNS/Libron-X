import SwiftUI

struct WorkspaceWindowsView: View {
    @Bindable var workspace: StudyWorkspace
    @RebuildViewState private var selection: WorkspaceWindowSelection
    @FocusState private var listFocused: Bool
    init(workspace: StudyWorkspace) {
        self.workspace = workspace
        _selection = RebuildViewState(initialValue: WorkspaceWindowSelection(workspace: workspace))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Selecciona una lectura para activarla o cerrarla."))
                .foregroundStyle(.secondary)
            List(selection: $selection.selectedID) {
                ForEach(selection.readers) { reader in
                    HStack(spacing: 12) {
                        Group {
                            if let kind = StudyResourceKind.identifying(reader) { StudyResourceIcon(kind: kind) }
                            else { Image(systemName: "book.closed").accessibilityHidden(true) }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(reader.resource.title)
                            Text(reader.currentReference ?? reader.resource.fileName)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if workspace.activeID == reader.id { Text(L("Activa")).font(.caption).foregroundStyle(.secondary) }
                        if reader.isMinimized { Text(L("Minimizada")).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 4).contentShape(Rectangle()).tag(reader.id)
                    .onTapGesture(count: 2) {
                        selection.selectedID = reader.id
                        selection.activateSelected()
                    }
                    .accessibilityAction(named: Text(L("Activar"))) {
                        selection.selectedID = reader.id; selection.activateSelected()
                    }
                }
            }
            .accessibilityLabel(L("Lecturas abiertas"))
            .focused($listFocused)
            .onKeyPress(.return) { selection.activateSelected() ? .handled : .ignored }
            HStack {
                Text(LF("{count} lecturas abiertas", ["count": String(selection.readers.count)]))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Cerrar ventana")) { selection.closeSelected() }
                    .disabled(selection.selectedReader == nil)
                Button(L("Activar")) { selection.activateSelected() }
                    .keyboardShortcut(.defaultAction).disabled(selection.selectedReader == nil)
            }
        }
        .padding(16)
        .onAppear { selection.reconcile(); listFocused = true }
        .onChange(of: workspace.orderedReaders.map(\.id)) { selection.reconcile() }
    }
}
