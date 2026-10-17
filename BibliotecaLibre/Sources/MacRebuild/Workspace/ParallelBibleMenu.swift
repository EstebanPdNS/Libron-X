import SwiftUI
import LibronixCore

struct ParallelBibleMenu: View {
    @Bindable var workspace: StudyWorkspace
    let reader: ReaderSession?
    var toolbarPresentation = true
    private var selected: ParallelBibleSet? {
        reader?.parallelSetID.flatMap { id in workspace.bibleGroups.first { $0.id == id } }
    }
    private var choices: [LibraryResource] {
        if reader?.parallelSetID != nil { return selected?.members.compactMap { $0.resolve(in: workspace.availableResources) } ?? [] }
        return workspace.availableBibleVersions
    }
    var body: some View {
        Menu {
            if let reader, reader.canSynchronizeBible {
                Menu(L("Grupo de Biblias")) {
                    Toggle(L("Todas las Biblias"), isOn: Binding(get: { reader.parallelSetID == nil }, set: { if $0 { workspace.selectParallelBibleGroup(nil, for: reader) } }))
                    ForEach(workspace.bibleGroups) { group in
                        Toggle(group.name, isOn: Binding(get: { reader.parallelSetID == group.id }, set: { if $0 { workspace.selectParallelBibleGroup(group.id, for: reader) } }))
                            .disabled(!group.members.contains { $0.resolve(in: workspace.availableResources)?.id == reader.resource.id })
                    }
                }
                if reader.parallelSetID != nil, selected == nil { Text(L("El grupo de Biblias ya no está disponible.")) }
                ForEach(choices) { resource in
                    Button((resource.id == reader.resource.id ? "✓ " : "") + parallelBibleMenuTitle(resource, in: choices)) {
                        workspace.selectParallelBible(resource, for: reader)
                    }.disabled(resource.id == reader.resource.id || reader.isLoading)
                }
                if let selected {
                    ForEach(selected.members.filter { $0.resolve(in: workspace.availableResources) == nil }) { member in
                        Button(member.title + " · " + L("Recurso no disponible")) {}.disabled(true)
                    }
                }
                if workspace.availableBibleVersions.isEmpty, reader.parallelSetID == nil { Text(L("Leyendo las Biblias disponibles…")) }
                Divider()
                Menu(L("Abrir en una lectura nueva")) {
                    ForEach(choices) { resource in
                        Button(parallelBibleMenuTitle(resource, in: choices)) { workspace.selectParallelBible(resource, for: reader, newReader: true) }
                    }
                }.disabled(choices.isEmpty)
                Divider()
            }
            Button(L("Configurar grupos…")) {
                if let reader { workspace.activate(reader) }; workspace.activeTool = .parallelSets
            }
        } label: {
            if toolbarPresentation { MacToolbarLabel(L("Recursos paralelos"), "books.vertical") }
            else { Text(L("Recursos paralelos")) }
        }
        .menuIndicator(.hidden).help(L("Recursos paralelos"))

    }
}

@MainActor extension StudyWorkspace {
    func selectParallelBibleGroup(_ groupID: UUID?, for reader: ReaderSession) {
        guard readers.contains(where: { $0 === reader }) else { return }
        if let groupID {
            guard let group = bibleGroups.first(where: { $0.id == groupID }),
                  group.members.contains(where: { $0.resolve(in: availableResources)?.id == reader.resource.id }) else { return }
        }
        activate(reader); reader.parallelSetID = groupID
    }

    func selectParallelBible(_ resource: LibraryResource, for reader: ReaderSession, newReader: Bool = false) {
        guard readers.contains(where: { $0 === reader }), reader.canSynchronizeBible, !reader.isLoading,
              let reference = reader.currentReference, availableResources.contains(where: { $0 == resource }) else { return }
        if let groupID = reader.parallelSetID {
            guard let group = bibleGroups.first(where: { $0.id == groupID }),
                  group.members.contains(where: { $0.resolve(in: availableResources)?.id == resource.id }) else { return }
        }
        if newReader {
            let copy = open(resource, destination: .init(ordinal: 0, reference: reference))
            copy.parallelSetID = reader.parallelSetID; copy.textScale = reader.textScale
        } else {
            activate(reader)
            reader.changeBibleVersion(to: resource, reference: reference) { [weak self, weak reader] in
                guard let self, let reader else { return }; self.connect(reader)
            }
        }
    }
}

/// Same titles can belong to different physical formats or installed editions.
func parallelBibleMenuTitle(_ resource: LibraryResource, in resources: [LibraryResource]) -> String {
    let matches = resources.filter { $0.title.localizedCaseInsensitiveCompare(resource.title) == .orderedSame }
    guard matches.count > 1 else { return resource.title }
    let suffix = resource.format.displayName + " · " + resource.fileName
    let sameFile = matches.filter { $0.format == resource.format && $0.fileName == resource.fileName }
    return resource.title + " · " + suffix + (sameFile.count > 1 ? " · " + resource.location.deletingLastPathComponent().path : "")
}
