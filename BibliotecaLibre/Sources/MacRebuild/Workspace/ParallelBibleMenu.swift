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
    // A single template image preserves both the native book and cross when
    // SwiftUI bridges this label into an AppKit menu button.
    private static let bibleIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let cover = NSBezierPath(roundedRect: NSRect(x: 5, y: 4.5, width: 12, height: 14), xRadius: 1.6, yRadius: 1.6)
            NSColor.black.setStroke(); cover.lineWidth = 1.15; cover.stroke()
            let spine = NSBezierPath()
            spine.move(to: NSPoint(x: 5, y: 18.5)); spine.line(to: NSPoint(x: 3.5, y: 18.5))
            spine.curve(to: NSPoint(x: 2, y: 17), controlPoint1: NSPoint(x: 2.5, y: 18.5), controlPoint2: NSPoint(x: 2, y: 18))
            spine.line(to: NSPoint(x: 2, y: 3))
            spine.curve(to: NSPoint(x: 3.5, y: 1.5), controlPoint1: NSPoint(x: 2, y: 2), controlPoint2: NSPoint(x: 2.5, y: 1.5))
            spine.line(to: NSPoint(x: 17, y: 1.5)); spine.lineWidth = 1.15; spine.stroke()
            let cross = NSBezierPath()
            // Cover center (11, 11.5); the complete cross stays inside it.
            cross.move(to: NSPoint(x: 11, y: 8.5)); cross.line(to: NSPoint(x: 11, y: 14.5))
            cross.move(to: NSPoint(x: 9, y: 12.5)); cross.line(to: NSPoint(x: 13, y: 12.5))
            cross.lineWidth = 1; cross.lineCapStyle = .round; cross.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Menu {
            if let reader, reader.canSynchronizeBible {
                Menu(L("Grupo de Biblias")) {
                    Toggle(L("Todas las Biblias"), isOn: Binding(get: { reader.parallelSetID == nil }, set: { if $0 { workspace.selectParallelBibleGroup(nil, for: reader) } }))
                    ForEach(workspace.bibleGroups) { group in
                        Toggle(group.name, isOn: Binding(get: { reader.parallelSetID == group.id }, set: { if $0 { workspace.switchParallelBibleGroup(group.id, for: reader) } }))
                            .disabled(reader.isLoading || !group.members.contains { $0.resolve(in: workspace.availableResources) != nil })
                    }
                }
                if reader.parallelSetID != nil, selected == nil { Text(L("El grupo de Biblias ya no está disponible.")) }
                Text(selected?.name ?? L("Todas las Biblias"))
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
            if toolbarPresentation { Label { Text(L("Recursos paralelos")) } icon: {
                    Image(nsImage: Self.bibleIcon).resizable().frame(width: 20, height: 20)
                }.labelStyle(.iconOnly).featureHelpTarget(.groups) }
            else { Text(L("Recursos paralelos")) }
        }
        .menuIndicator(.hidden).help(L("Recursos paralelos"))

    }
}

@MainActor extension StudyWorkspace {
    func switchParallelBibleGroup(_ groupID: UUID, for reader: ReaderSession) {
        guard readers.contains(where: { $0 === reader }), !reader.isLoading,
              let group = bibleGroups.first(where: { $0.id == groupID }) else { return }
        if group.members.contains(where: { $0.resolve(in: availableResources)?.id == reader.resource.id }) {
            selectParallelBibleGroup(groupID, for: reader); return
        }
        guard reader.canSynchronizeBible, let reference = reader.currentReference else { return }
        let candidates = group.members.compactMap { $0.resolve(in: availableResources) }
        activate(reader)
        reader.changeBibleVersion(candidates: candidates, reference: reference) { [weak self, weak reader] in
            guard let self, let reader else { return }
            if self.bibleGroups.contains(where: { $0.id == groupID && $0.members.contains(where: { $0.resolve(in: self.availableResources)?.id == reader.resource.id }) }) {
                reader.parallelSetID = groupID
            } else { reader.parallelSetID = nil }
            self.connect(reader)
        }
    }

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
