import SwiftUI

struct PaneLayoutPicker: View {
    @Bindable var workspace: StudyWorkspace
    @RebuildViewState private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: { MacToolbarMenuLabel(L("Organizar ventanas"), "rectangle.split.2x1") }
            .help(L("Organizar ventanas"))
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
                PaneLayoutPanel(workspace: workspace) { expanded = false }
            }
    }
}

/// The toolbar arranges visible readers; a title-bar popup moves its explicit
/// target only, even if focus changes while the popup is open.
struct PaneLayoutPanel: View {
    @Bindable var workspace: StudyWorkspace
    var targetReader: ReaderSession? = nil
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Organizar ventanas")).font(.headline)
            if let targetReader {
                Text(targetReader.resource.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(L("Elige la posición de la lectura activa.")).font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(96)), count: 3), spacing: 12) {
                ForEach(PaneLayout.allCases) { layout in
                    LayoutDiagram(layout: layout) { slot in
                        if let targetReader { workspace.place(targetReader, layout: layout, slot: slot) }
                        else { workspace.apply(layout, activeSlot: slot) }
                        dismiss()
                    }.disabled(targetReader == nil && workspace.activeReader == nil)
                }
            }.environment(\.layoutDirection, .leftToRight)
            Divider()
            if let targetReader {
                action("Ampliar o restaurar panel", "arrow.up.left.and.arrow.down.right") {
                    workspace.activate(targetReader); targetReader.isMaximized.toggle()
                }
                action("Minimizar panel", "minus") { workspace.minimize(targetReader) }
                action("Cerrar panel", "xmark") { workspace.close(targetReader) }
            } else {
                action("Cascada", "square.3.layers.3d") { workspace.arrange(.cascade) }
                action("Mosaico vertical", "rectangle.split.2x1") { workspace.arrange(.vertical) }
                action("Mosaico horizontal", "rectangle.split.1x2") { workspace.arrange(.horizontal) }
                Divider()
                action("Siguiente lectura", "arrow.right") { workspace.cycleReader() }
                action("Lectura anterior", "arrow.left") { workspace.cycleReader(backwards: true) }
                action("Ventanas…", "macwindow.on.rectangle") { workspace.activeTool = .windows }
                Divider()
                action("Cerrar todo y abrir Inicio", "house") { workspace.closeAll(); workspace.showsHome = true }
            }
            Divider()
            Button(L("¿Qué es esto?"), systemImage: "questionmark.circle") { FeatureHelp.shared.show(.workspace) }
        }.padding(16).frame(width: 340).modifier(MacPanelControlPresentation())
    }
    private func action(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button { action(); dismiss() } label: { Label(L(title), systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.plain).padding(.vertical, 2)
    }
}
private struct LayoutDiagram: View {
    let layout: PaneLayout
    let selected: (Int) -> Void
    @RebuildViewState private var hovered: Int?
    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(layout.frames.enumerated()), id: \.offset) { index, _ in
                let rect = layout.diagramRect(for: index, size: geometry.size)
                Button { selected(index) } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovered == index ? Color.accentColor : Color.primary.opacity(0.09))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .accessibilityLabel(L(layout.title) + " · " + LF("Posición {number}", ["number": String(index + 1)]))
                    .help(L(layout.title) + " · " + LF("Posición {number}", ["number": String(index + 1)]))
            }
        }
        .frame(width: 96, height: 62)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): hovered = layout.diagramSlot(at: point, size: .init(width: 96, height: 62))
            case .ended: hovered = nil
            }
        }
    }
}
