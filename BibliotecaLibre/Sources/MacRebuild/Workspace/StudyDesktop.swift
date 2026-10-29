import LibronixCore
import SwiftUI

struct StudyDesktop: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable private var updater = AppUpdater.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .underPageBackgroundColor)
                    if workspace.showsHome {
                        VStack(spacing: 14) {
                            Image(systemName: "books.vertical").font(.system(size: 36)).foregroundStyle(.secondary)
                            Text(L("Espacio de trabajo")).font(.title2)
                            Button(L("Abrir Mi biblioteca")) { openWindow(id: "library") }
                            Text(L("Abre libros y organízalos dentro de esta ventana.")).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    ForEach(workspace.showsHome ? [] : workspace.presentedReaders) { reader in
                        let focused = workspace.focusedReaderID == reader.id
                        let hiddenByFocus = workspace.focusedReaderID != nil && !focused
                        let frame = focused || reader.isMaximized ? PaneFrame(x: 0, y: 0, width: 1, height: 1) : reader.frame
                        InternalReaderPane(reader: reader, workspace: workspace, canvas: geometry.size, focused: focused)
                            .modifier(AppInterfaceLanguage())
                            .frame(width: max(1, frame.width * geometry.size.width), height: max(1, frame.height * geometry.size.height))
                            .offset(x: frame.x * geometry.size.width, y: frame.y * geometry.size.height)
                            .opacity(hiddenByFocus ? 0 : 1)
                            .allowsHitTesting(!hiddenByFocus).accessibilityHidden(hiddenByFocus)
                            .zIndex(workspace.stackingLevel(of: reader))
                    }
                    // The active resize ring sits above all neighboring panes. Its
                    // four-point outward reach owns a shared seam on either side.
                    if !workspace.showsHome, workspace.focusedReader == nil, let reader = workspace.activeReader,
                       !reader.isMaximized, !reader.isMinimized {
                        let frame = reader.frame
                        PaneResizeOverlay(reader: reader, workspace: workspace, canvas: geometry.size)
                            .frame(width: frame.width * geometry.size.width + 8,
                                   height: frame.height * geometry.size.height + 8)
                            .offset(x: frame.x * geometry.size.width - 4,
                                    y: frame.y * geometry.size.height - 4)
                            .zIndex(9_000)
                    }
                    if let preview = workspace.snapPreview, !workspace.showsHome, workspace.focusedReader == nil {
                        RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2))
                            .padding(4)
                            .frame(width: preview.width * geometry.size.width, height: preview.height * geometry.size.height)
                            .offset(x: preview.x * geometry.size.width, y: preview.y * geometry.size.height)
                            .allowsHitTesting(false).accessibilityHidden(true).zIndex(10_000)
                    }
                }.background(PaneCanvasSurface(workspace: workspace)).coordinateSpace(name: "studyCanvas").clipped()
            }.environment(\.layoutDirection, .leftToRight)
            if workspace.focusedReader == nil && workspace.readers.contains(where: \.isMinimized) {
                HStack {
                    ForEach(workspace.readers.filter(\.isMinimized)) { reader in
                        Button(reader.resource.title) { workspace.activate(reader) }.lineLimit(1)
                    }; Spacer()
                }.padding(5).background(.bar)
            }
            if workspace.focusedReader == nil { Divider()
            HStack {
                Text(workspace.activeReader?.resource.title ?? L("Listo")).lineLimit(1)
                Spacer()
                Text(LF("{panes} paneles · {resources} recursos", ["panes": String(workspace.readers.count), "resources": String(workspace.availableResources.count)]))
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 23) }
        }
        .background(BibleVersionKeyboardRouting(workspace: workspace))
        .task(id: workspace.availableResources + workspace.bibleReaders.map(\.resource)) {
            await workspace.refreshBibleVersionChoices()
            await workspace.dictionary.prepare(workspace.availableResources)
        }
        .sheet(isPresented: $updater.showsPanel) {
            UpdatePanel(workspace: workspace).modifier(AppInterfaceLanguage())
        }
        .toolbar {
            if workspace.focusedReader != nil {
                ToolbarItem(placement: .navigation) {
                    Button(L("Salir de lectura concentrada")) { workspace.exitFocusedReading() }
                }
            } else { MainWorkspaceToolbar(workspace: workspace) }
        }
        .toolbarRole(.editor)
        .modifier(MacWorkspaceTitlePresentation())
        .sheet(item: $workspace.activeTool) { tool in
            WorkspaceToolsView(tool: tool, workspace: workspace).modifier(AppInterfaceLanguage())
                .interactiveDismissDisabled(tool == .researchInbox)
        }
        .alert("Libron-X", isPresented: Binding(get: { workspace.error != nil && workspace.activeTool != .favorites }, set: { if !$0 { workspace.error = nil } })) {
            Button(L("Aceptar")) { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
    }
}

struct InternalReaderPane: View {
    @Bindable var reader: ReaderSession
    let workspace: StudyWorkspace
    let canvas: CGSize
    var focused = false
    @RebuildViewState private var dragOrigin: PaneFrame?
    @RebuildViewState private var pointerOrigin: CGPoint?
    @RebuildViewState private var canvasOrigin: CGPoint?
    @RebuildViewState private var showsWarnings = false
    var body: some View {
        VStack(spacing: 0) {
            if !focused {
                titleBar
                if reader.isCommentary { ReaderCommentaryToolbar(reader: reader, workspace: workspace) }
                else { ResourceReaderToolbar(reader: reader, workspace: workspace) }
                if reader.isDevotional { DevotionalDateBar(reader: reader, workspace: workspace) }
                Divider()
            }
            if !focused && reader.showsLocator {
                HStack {
                    Text(reader.currentReference ?? reader.page.map { LF("Artículo {number}", ["number": String($0.destination.ordinal + 1)]) } ?? L("Sin ubicación")).font(.caption)
                    Spacer()
                    Button(L("Inicio")) { workspace.activate(reader); reader.load(.init(ordinal: 0)) }.disabled(reader.page == nil)
                    Button(L("Final")) { workspace.activate(reader); if let page = reader.page { reader.load(.init(ordinal: page.sectionCount - 1)) } }.disabled(reader.page == nil)
                }.padding(7).background(.bar)
                Divider()
            }
            if !focused && reader.showsFind { ReaderFindBar(reader: reader, activate: { workspace.activate(reader) }); Divider() }
            if let error = reader.error {
                HStack { MacToolbarLabel(L("Error de lectura"), "exclamationmark.triangle"); Text(error).textSelection(.enabled); Spacer() }
                    .font(.callout).padding(10).background(Color.orange.opacity(0.12))
            }
            if reader.commentarySourceID != nil, !reader.isLoading,
               (reader.page == nil || reader.page?.destination.commentaryChapter != nil && reader.commentaryReference.flatMap(LegacyPassageQuery.sourceReference).flatMap({ reader.page?.commentaryLocations[$0.normalizedKey] }) == nil),
               reader.error == nil, let reference = reader.commentaryReference {
                Text(LF("No hay comentario para {reference}.", ["reference": reference]))
                    .foregroundStyle(.secondary).textSelection(.enabled).padding(12)
            }
            HSplitView {
                if !focused && reader.showsContents {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(reader.page?.entries ?? []) { entry in
                                Button { workspace.activate(reader); reader.load(.init(ordinal: entry.ordinal)) } label: {
                                    Text(entry.title).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(4).padding(.leading, CGFloat(entry.depth) * 12)
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(minWidth: 120, idealWidth: 180, maxWidth: 280)
                }
                if reader.isCommentary {
                    ReaderCommentaryView(reader: reader, workspace: workspace)
                } else if let oeb = reader.page?.oeb {
                    ReaderOEBView(reader: reader, page: oeb, activate: { workspace.activate(reader) }).frame(minWidth: 50)
                        .opacity(reader.textScale == 0 ? 0 : 1)
                        .allowsHitTesting(reader.textScale > 0).accessibilityHidden(reader.textScale == 0)
                } else {
                    ReaderArticleFlowView(reader: reader, workspace: workspace,
                        pages: reader.readingFlowPages, selectionRevision: reader.selectionRequest,
                        scale: reader.renderingScale, fontsRevision: reader.sourceFontsRevision,
                        personalNotes: workspace.personal.noteLinks(for: reader.resource),
                        highlights: reader.highlights, visibleLines: reader.visibleInterlinearLines)
                    .frame(minWidth: 50)
                    .opacity(reader.textScale == 0 ? 0 : 1)
                    .allowsHitTesting(reader.textScale > 0).accessibilityHidden(reader.textScale == 0)
                }
            }
            if !focused { HStack(spacing: 8) {
                Button { workspace.activate(reader); reader.previousArticle() } label: { MacToolbarLabel(L("Artículo anterior"), "chevron.up") }
                    .disabled(!reader.canGoToPreviousArticle).help(L("Artículo anterior"))
                Button { workspace.activate(reader); reader.nextArticle() } label: { MacToolbarLabel(L("Artículo siguiente"), "chevron.down") }
                    .disabled(!reader.canGoToNextArticle).help(L("Artículo siguiente"))
                if reader.isLoading { ProgressView().controlSize(.mini); Button(L("Cancelar"), action: reader.cancel) }
                else if reader.page != nil { Text(reader.readingPositionLabel(language: AppPreferences.shared.language)).font(.system(size: 11)) }
                Spacer()
                if reader.page?.warning != nil || !reader.presentationWarnings.isEmpty {
                    Button { showsWarnings.toggle() } label: { MacToolbarLabel(L("Detalles de lectura y formato"), "exclamationmark.circle") }.help(L("Detalles de lectura y formato"))
                        .popover(isPresented: $showsWarnings) {
                            ScrollView {
                                Text(([reader.page?.warning].compactMap { $0 } + reader.presentationWarnings).joined(separator: "\n\n"))
                                    .font(.callout).textSelection(.enabled).padding().frame(width: 380, alignment: .leading)
                            }.frame(maxHeight: 320)
                        }
                }

            }.buttonStyle(.borderless).padding(.leading, 8).frame(height: 26).background(.bar) }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .readerHelpTarget(reader.isDictionary ? .dictionary : (reader.canSynchronizeBible ? .bibleReading : .navigation), reader: reader, workspace: workspace)
        .clipShape(paneShape)
        .overlay(paneShape.strokeBorder(Color.gray.opacity(workspace.activeID == reader.id ? 0.45 : 0.25), lineWidth: 1))
        .overlay {
            if !focused && !reader.isMaximized { PaneResizeOverlay(reader: reader, workspace: workspace, canvas: canvas) }
        }
        .transaction { $0.animation = nil }
        .shadow(color: .black.opacity(workspace.activeID == reader.id ? 0.16 : 0.08), radius: 5, y: 2)
        .accessibilityElement(children: .contain).accessibilityLabel(reader.displayTitle)
    }
    private var paneShape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }
    private var titleBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                MacPanelControl(label: "Cerrar panel", color: Color(red: 1, green: 0.37, blue: 0.34), symbol: "xmark") { workspace.close(reader) }
                MacPanelControl(label: "Minimizar panel", color: Color(red: 1, green: 0.74, blue: 0.18), symbol: "minus") { workspace.minimize(reader) }
                MacPanelControl(label: "Ampliar o restaurar panel", color: Color(red: 0.16, green: 0.79, blue: 0.26), symbol: "plus") {
                    workspace.toggleMaximized(reader)
                }
            }
            Text(reader.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .overlay {
                    PanePointerSurface(cursor: .openHand, doubleClick: {
                        workspace.toggleMaximized(reader)
                    }, began: { point in
                        guard canvas.width > 0, canvas.height > 0 else { return }
                        workspace.activate(reader)
                        pointerOrigin = point.windowPoint
                        canvasOrigin = .init(x: point.canvasX, y: point.canvasY)
                        dragOrigin = reader.isMaximized ? PaneFrame(x: 0, y: 0, width: 1, height: 1) : reader.frame
                    }, changed: { point in
                        guard let start = pointerOrigin, var frame = dragOrigin, canvas.width > 0, canvas.height > 0 else { return }
                        let dx = (point.windowPoint.x - start.x) / canvas.width, dy = (start.y - point.windowPoint.y) / canvas.height
                        guard abs(dx) + abs(dy) > 0.003 else { return }
                        if reader.isMaximized || reader.unsnappedFrame != nil {
                            let restored = reader.unsnappedFrame ?? PaneFrame(x: 0.1, y: 0.1, width: 0.76, height: 0.8)
                            let anchor = canvasOrigin ?? .zero
                            let fraction = min(1, max(0, (anchor.x / canvas.width - frame.x) / frame.width))
                            frame = PaneFrame(x: anchor.x / canvas.width - fraction * restored.width,
                                              y: anchor.y / canvas.height - 17 / canvas.height,
                                              width: restored.width, height: restored.height)
                            dragOrigin = frame; reader.isMaximized = false; reader.unsnappedFrame = nil
                        }
                        reader.frame = frame.moved(by: .init(width: dx * canvas.width, height: dy * canvas.height), canvas: canvas)
                        // The native surface converts the pointer to the fixed canvas coordinate system.
                        workspace.snapPreview = PaneSnap.target(at: .init(x: point.canvasX, y: point.canvasY), canvas: canvas)?.frame
                    }, ended: {
                        if let preview = workspace.snapPreview { workspace.place(reader, in: preview) }
                        workspace.snapPreview = nil; dragOrigin = nil; pointerOrigin = nil; canvasOrigin = nil
                    }).padding(.top, 7) // The upper resize strip never owns a hand cursor.
                }
            Color.clear.frame(width: 76, height: 1)
        }.padding(.horizontal, 7).frame(height: 34)
            .background(.regularMaterial)
            .background(PaneTitleContextMenu(reader: reader, workspace: workspace))
            .simultaneousGesture(TapGesture().onEnded {
                workspace.activate(reader)
                NSApplication.shared.keyWindow?.makeFirstResponder(nil)
            })
    }
}

/// macOS-style traffic lights operate on the embedded panel, not the application window.
private struct MacPanelControl: View {
    let label: String
    let color: Color
    let symbol: String
    let action: () -> Void
    @RebuildViewState private var hovering = false
    var body: some View {
        Button(action: action) {
            Circle().fill(color)
                .overlay(Circle().stroke(.black.opacity(0.12), lineWidth: 0.5))
                .overlay {
                    if hovering { Image(systemName: symbol).font(.system(size: 7, weight: .bold)).foregroundStyle(.black.opacity(0.65)) }
                }
                .frame(width: 12, height: 12).frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }.accessibilityLabel(L(label)).help(L(label)).featureHelpTarget(.workspace)
    }
}
