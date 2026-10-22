import SwiftUI
import LibronixCore

@MainActor extension StudyResourceKind {
    var title: String {
        switch self {
        case .bible: "Biblias"
        case .dictionary: "Diccionarios"
        case .commentary: "Comentarios bíblicos"
        }
    }
    func resources(in workspace: StudyWorkspace) -> [LibraryResource] {
        switch self {
        case .bible: workspace.availableBibleVersions
        case .dictionary: workspace.dictionaryGroup
        case .commentary: workspace.commentaryResources
        }
    }
    func open(_ resource: LibraryResource, in workspace: StudyWorkspace) {
        guard resources(in: workspace).contains(where: { $0.id == resource.id }) else { return }
        switch self {
        case .bible:
            workspace.open(resource, destination: workspace.bibleReaders.last?.currentReference.map { .init(ordinal: 0, reference: $0) })
        case .dictionary: workspace.dictionary.openInside(resource: resource, workspace: workspace)
        case .commentary: workspace.openCommentary(resource)
        }
    }
}

/// All three toolbar entry points share the same native searchable chooser.
struct StudyResourcePickerButton: View {
    let workspace: StudyWorkspace
    let kind: StudyResourceKind
    @RebuildViewState private var presented = false
    var body: some View {
        Button { presented.toggle() } label: { StudyResourceLabel(title: kind.title, kind: kind) }
            .help(L(kind.title)).accessibilityLabel(L(kind.title))
            .macToolbarPopover(isPresented: $presented, size: NSSize(width: 520, height: 440)) {
                StudyResourcePicker(workspace: workspace, kind: kind) { presented = false }
            }
    }
}

struct StudyResourcePicker: View {
    let workspace: StudyWorkspace
    let kind: StudyResourceKind
    let dismiss: () -> Void
    var resourcesOverride: [LibraryResource]? = nil
    var initialSelection: String? = nil
    var openResource: ((LibraryResource) -> Void)? = nil
    var openInNewReading: ((LibraryResource) -> Void)? = nil
    var bibleReader: ReaderSession? = nil
    @RebuildViewState private var query = ""
    @RebuildViewState private var selectedID: String?
    @RebuildViewState private var sortOrder = [LibraryResourceSort(.title)]
    @FocusState private var searching: Bool
    @RebuildViewState private var opening = false
    private var candidates: [LibraryResource] {
        if let bibleReader {
            if let id = bibleReader.parallelSetID {
                return workspace.bibleGroups.first { $0.id == id }?.members.compactMap { $0.resolve(in: workspace.availableResources) } ?? []
            }
            return workspace.availableBibleVersions
        }
        return resourcesOverride ?? kind.resources(in: workspace)
    }
    private var resources: [LibraryResource] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return candidates.filter { resource in
            let text = [resource.title, resource.author ?? "", LibraryField.language.value(resource), resource.fileName].joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }.sortedForLibrary(using: sortOrder)
    }
    private var selected: LibraryResource? { resources.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StudyResourceIcon(kind: kind)
                Text(L(kind.title)).font(.headline)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .accessibilityLabel(L("Cerrar")).keyboardShortcut(.cancelAction)
            }
            if let bibleReader {
                HStack {
                    Menu {
                        Button(L("Todas las Biblias")) { workspace.selectParallelBibleGroup(nil, for: bibleReader) }
                        ForEach(workspace.bibleGroups) { group in
                            Button(group.name) { workspace.switchParallelBibleGroup(group.id, for: bibleReader) }
                                .disabled(bibleReader.isLoading || !group.members.contains { $0.resolve(in: workspace.availableResources) != nil })
                        }
                    } label: {
                        Text(bibleReader.parallelSetID.flatMap { id in workspace.bibleGroups.first { $0.id == id }?.name } ?? L("Todas las Biblias"))
                    }.accessibilityLabel(L("Grupo de Biblias"))
                    Spacer()
                    Button(L("Configurar grupos…")) { workspace.activate(bibleReader); workspace.activeTool = .parallelSets; dismiss() }
                }
            }
            TextField(L("Buscar título, autor, idioma o archivo"), text: $query)
                .macInputStyle().focused($searching).onSubmit(open)
            NativeStudyResourceTable(resources: resources, selectedID: $selectedID, sortOrder: $sortOrder,
                open: { open($0) })
            HStack {
                Text(LF("{count} recursos", ["count": "\(resources.count)"])).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let openInNewReading {
                    Button(L("Abrir en una lectura nueva")) {
                        guard let selected else { return }; openInNewReading(selected); dismiss()
                    }.disabled(selected == nil)
                }
                Button(L("Abrir recurso"), action: open).keyboardShortcut(.defaultAction).disabled(selected == nil)
            }
        }
        .padding(16).frame(width: 520, height: 440).modifier(MacPanelControlPresentation())
        .onAppear { selectedID = initialSelection ?? resources.first?.id; searching = true }
        .onChange(of: query) { _, _ in
            if selected == nil { selectedID = resources.first?.id }
        }
    }
    private func open() { open(selectedID) }
    private func open(_ id: String?) {
        guard !opening, let resource = resources.first(where: { $0.id == id }) else { return }
        opening = true
        if let openResource { openResource(resource) }
        else { kind.open(resource, in: workspace) }
        dismiss()
    }
}
