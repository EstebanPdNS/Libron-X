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
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Trasladar y redimensionar")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                snapButton(.left, title: "Izquierda")
                snapButton(.right, title: "Derecha")
                snapButton(.top, title: "Superior")
                snapButton(.bottom, title: "Inferior")
            }
            Divider()
            Text(L(targetReader == nil ? "Rellenar y ordenar" : "Esquinas")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                if targetReader != nil {
                    snapButton(.topLeft, title: "Superior izquierda")
                    snapButton(.topRight, title: "Superior derecha")
                    snapButton(.bottomLeft, title: "Inferior izquierda")
                    snapButton(.bottomRight, title: "Inferior derecha")
                } else {
                    snapButton(.full, title: "Ampliar o restaurar panel")
                    compactLayout(.halves)
                    compactLayout(.leftAndTwo)
                    compactLayout(.quarters)
                }
            }
            Divider()
            HStack {
            Menu {
                ForEach(PaneLayout.allCases) { layout in
                    Menu(L(layout.title)) {
                        ForEach(Array(layout.frames.indices), id: \.self) { slot in
                            Button(LF("Posición {number}", ["number": String(slot + 1)])) {
                                if let targetReader { workspace.place(targetReader, layout: layout, slot: slot) }
                                else { workspace.apply(layout, activeSlot: slot) }
                                dismiss()
                            }
                        }
                    }
                }
            Divider()
            if let targetReader {
                action("Ampliar o restaurar panel", "arrow.up.left.and.arrow.down.right") {
                    workspace.toggleMaximized(targetReader)
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
            }
            label: {
                Text(L("Más opciones")).font(.callout)
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible)
            .padding(.horizontal, 10).frame(height: 30)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 8)
            Button { FeatureHelp.shared.show(.workspace) } label: {
                Label(L("¿Qué es esto?"), systemImage: "questionmark.circle").font(.callout)
            }.buttonStyle(.borderless).padding(.horizontal, 10).frame(height: 30)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }.controlSize(.regular)
        }.padding(16).frame(width: 310).controlSize(.regular).modifier(MacPanelControlPresentation())
    }
    private func snapButton(_ snap: PaneSnap, title: String) -> some View {
        Button {
            if let reader = targetReader ?? workspace.activeReader {
                if snap == .full { workspace.toggleMaximized(reader) }
                else { workspace.place(reader, in: snap.frame) }
            }
            dismiss()
        } label: { CompactWindowDiagram(frames: [snap.frame]) }
            .buttonStyle(.plain).help(L(title)).accessibilityLabel(L(title))
            .disabled(targetReader == nil && workspace.activeReader == nil)
    }
    private func compactLayout(_ layout: PaneLayout) -> some View {
        Button {
            if let targetReader { workspace.place(targetReader, layout: layout, slot: 0) }
            else { workspace.apply(layout, activeSlot: 0) }
            dismiss()
        } label: { CompactWindowDiagram(frames: layout.frames) }
            .buttonStyle(.plain).help(L(layout.title)).accessibilityLabel(L(layout.title))
            .disabled(targetReader == nil && workspace.activeReader == nil)
    }
    private func action(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button { action(); dismiss() } label: { Label(L(title), systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.plain).padding(.vertical, 2)
    }
}
private struct CompactWindowDiagram: View {
    let frames: [PaneFrame]
    @RebuildViewState private var hovered = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.65), lineWidth: 1.5)
            ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index == 0 ? Color.primary.opacity(0.8) : Color.primary.opacity(0.18))
                    .frame(width: max(1, frame.width * 23 - 2), height: max(1, frame.height * 16 - 2))
                    .offset(x: (frame.x + frame.width / 2 - 0.5) * 23, y: (frame.y + frame.height / 2 - 0.5) * 16)
            }
        }.frame(width: 29, height: 22).environment(\.layoutDirection, .leftToRight).padding(5)
            .background(hovered ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}
