import SwiftUI
import LibronixCore

struct ReaderCommentaryToolbar: View {
    let reader: ReaderSession
    let workspace: StudyWorkspace
    @RebuildViewState private var choosingResource = false
    var body: some View {
        GeometryReader { geometry in
            MacReaderToolbarSurface {
                HStack(spacing: 8) {
                    StudyResourceIcon(kind: .commentary).foregroundStyle(.secondary)
                    Text(reader.commentaryReference ?? L("Comentarios")).font(.callout).lineLimit(1)
                    if reader.commentaryReference != nil && reader.commentaryChoicesReference != reader.commentaryReference {
                        ProgressView().controlSize(.mini).frame(width: 14).accessibilityLabel(L("Buscar"))
                    }
                    Spacer(minLength: 4)
                    if LibronMetadata.deriving(reader.resource).resourceType == "Comentario bíblico" {
                        resourceControls
                    }
                    if geometry.size.width >= 820 {
                        MacReaderControlGroup {
                            Button { workspace.activate(reader); reader.goBack() } label: { MacToolbarLabel(L("Atrás"), "chevron.left") }
                                .help(L("Atrás")).disabled(!reader.canGoBack)
                            Button { workspace.activate(reader); reader.goForward() } label: { MacToolbarLabel(L("Adelante"), "chevron.right") }
                                .help(L("Adelante")).disabled(!reader.canGoForward)
                        }
                    }
                    MacReaderControlGroup {
                        if reader.commentarySourceID != nil {
                            Button { workspace.setCommentaryFollowing(!reader.followsCommentary, for: reader) } label: {
                                MacToolbarLabel(L("Seguir la Biblia de origen"), "link")
                                    .foregroundStyle(reader.followsCommentary ? Color.accentColor : Color.primary)
                            }.help(L("Seguir la Biblia de origen"))
                                .accessibilityValue(L(reader.followsCommentary ? "Activado" : "Desactivado"))
                        }
                        if geometry.size.width >= 700 {
                            Button { workspace.activate(reader); reader.showFind() } label: { MacToolbarLabel(L("Buscar en este recurso"), "magnifyingglass") }
                                .help(L("Buscar en este recurso"))
                            Button { workspace.activate(reader); reader.showsContents.toggle() } label: { MacToolbarLabel(L("Contenido"), "sidebar.left") }
                                .help(L("Contenido"))
                        }
                        ReaderZoomMenu(reader: reader, activate: { workspace.activate(reader) })
                        if geometry.size.width >= 560 {
                            Button { workspace.activate(reader); workspace.addNoteForSelection(reader) } label: { MacToolbarLabel(L("Agregar nota"), "square.and.pencil") }
                                .help(L("Agregar nota"))
                            ReaderMarkupMenu(workspace: workspace, reader: reader)
                        }
                        actionsMenu
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }.padding(.horizontal, 8).frame(height: 44).background(.bar)
        .transaction { $0.animation = nil }
        .task(id: CommentaryCoverageRequest(reference: reader.commentaryReference, resources: workspace.commentaryResources)) {
            let reference = reader.commentaryReference
            reader.commentaryChoicesReference = nil; reader.commentaryChoiceIDs = []
            guard let reference else { return }
            do {
                let matches = try await CommentaryCoverageCatalog.shared.matching(workspace.commentaryResources, reference: reference)
                try Task.checkCancellation()
                guard reader.commentaryReference == reference else { return }
                reader.commentaryChoiceIDs = Set(matches); reader.commentaryChoicesReference = reference
            } catch is CancellationError { }
            catch { reader.presentationWarnings.append(error.localizedDescription) }
        }
    }
    private var resourceControls: some View {
        MacReaderControlGroup {
            Button { workspace.cycleCommentary(reader, backwards: true) } label: { MacToolbarLabel(L("Comentario anterior"), "chevron.left") }
                .help(L("Comentario anterior")).disabled(workspace.commentaryChoices(for: reader).count < 2 || reader.isLoading)
            Button { workspace.activate(reader); choosingResource.toggle() } label: { StudyResourceLabel(title: "Comentarios bíblicos", kind: .commentary) }
                .help(L("Elegir comentario bíblico")).accessibilityLabel(L("Elegir comentario bíblico"))
                .macToolbarPopover(isPresented: $choosingResource, size: NSSize(width: 520, height: 440)) {
                    StudyResourcePicker(workspace: workspace, kind: .commentary, dismiss: { choosingResource = false },
                        resourcesOverride: workspace.commentaryChoices(for: reader), initialSelection: reader.resource.id,
                        openResource: { workspace.openCommentary($0, replacing: reader) })
                }
            Button { workspace.cycleCommentary(reader) } label: { MacToolbarLabel(L("Comentario siguiente"), "chevron.right") }
                .help(L("Comentario siguiente")).disabled(workspace.commentaryChoices(for: reader).count < 2 || reader.isLoading)
        }
    }
    private var actionsMenu: some View {
        Menu {
            Button(L("Atrás")) { workspace.activate(reader); reader.goBack() }.disabled(!reader.canGoBack)
            Button(L("Adelante")) { workspace.activate(reader); reader.goForward() }.disabled(!reader.canGoForward)
            Menu(L("Biblia de origen")) {
                Button(L("Biblia activa")) { workspace.chooseCommentarySource(nil, for: reader, activeBible: true) }
                ForEach(workspace.bibleReaders) { bible in
                    Button(bible.resource.title) { workspace.chooseCommentarySource(bible, for: reader, activeBible: false) }
                }
            }
            Button(L("Contenido")) { workspace.activate(reader); reader.showsContents.toggle() }
            Button(L("Buscar en este recurso")) { workspace.activate(reader); reader.showFind() }
            Button(L("Agregar nota")) { workspace.activate(reader); workspace.addNoteForSelection(reader) }
            Divider()
            ReaderOutputMenuItems(reader: reader, workspace: workspace)
        } label: { MacToolbarLabel(L("Acciones de lectura"), "ellipsis") }
            .menuIndicator(.hidden).help(L("Acciones de lectura"))
    }

}

struct ReaderCommentaryView: View {
    let reader: ReaderSession
    let workspace: StudyWorkspace
    private var illustrations: [LegacyGraphicAsset] {
        reader.page?.graphics.filter { !ReaderImageRenderer.isDecoration($0) } ?? []
    }
    var body: some View {
        GeometryReader { geometry in
            if illustrations.isEmpty { text }
            else if geometry.size.width >= 560 {
                HSplitView {
                    text.frame(minWidth: 220, idealWidth: geometry.size.width * 0.52)
                    gallery.frame(minWidth: 220, idealWidth: geometry.size.width * 0.48)
                }
            } else {
                VSplitView {
                    text.frame(minHeight: 100)
                    gallery.frame(minHeight: 120, idealHeight: geometry.size.height * 0.42)
                }
            }
        }
    }
    private var text: some View {
        ReaderTextView(text: reader.page?.text ?? "", selection: reader.selectedRange, identity: reader.page?.destination,
            selectionRequest: reader.selectionRequest, content: reader.page?.content, typography: reader.page?.typography,
            graphics: reader.page?.graphics ?? [], detachedImages: true, scale: reader.renderingScale,
            highlights: reader.highlights, personalNotes: workspace.personal.noteLinks(for: reader.resource),
            notePersonalState: workspace.personal, onEditNote: { workspace.editPersonalNote($0) },
            onCreateNote: { reader.selectedRange = $0; workspace.activate(reader); workspace.addNoteForSelection(reader) }, sourceFontsRevision: reader.sourceFontsRevision,
            onWarnings: { reader.presentationWarnings = $0 }, onSelection: { reader.selectedRange = $0 },
            resource: reader.resource, inlineLinks: reader.page?.inlineLinks ?? [],
            onOpenLink: { resource, destination, newReader in
                workspace.openInlineLink(resource, destination: destination, from: reader, newReader: newReader)
            }, resolveLinkResource: { source, link in try workspace.resourceForInlineLink(link, source: source) },
            onDictionaryLookup: { reader.onDictionaryLookup?($0) },
            onQuickDictionaryLookup: { word, view, rect in reader.onQuickDictionaryLookup?(word, view, rect) },
            activate: { workspace.activate(reader) })
    }
    private var gallery: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForEach(Array(illustrations.enumerated()), id: \.offset) { _, asset in
                    if let image = ReaderImageRenderer.decode(asset.data) {
                        Button { MapPreview.show(image: image, title: reader.displayTitle) } label: {
                            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.plain).help(L("Ampliar imagen"))
                            .accessibilityLabel(L("Ampliar imagen"))
                    }
                }
            }.padding(16)
        }.background(Color(nsColor: .textBackgroundColor))
    }
}
