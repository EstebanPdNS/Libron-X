import SwiftUI
import LibronixCore

struct ReaderCommentaryToolbar: View {
    let reader: ReaderSession
    let workspace: StudyWorkspace
    var body: some View {
        MacReaderToolbarSurface {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
                Text(reader.commentaryReference ?? L("Comentarios")).font(.callout).lineLimit(1)
                Spacer(minLength: 4)
                MacReaderControlGroup {
                    Button { workspace.activate(reader); reader.goBack() } label: {
                        MacToolbarLabel(L("Atrás"), "chevron.left")
                    }.help(L("Atrás")).disabled(!reader.canGoBack)
                    Button { workspace.activate(reader); reader.goForward() } label: {
                        MacToolbarLabel(L("Adelante"), "chevron.right")
                    }.help(L("Adelante")).disabled(!reader.canGoForward)
                }
                MacReaderControlGroup {
                    if reader.commentarySourceID != nil {
                        Button { workspace.setCommentaryFollowing(!reader.followsCommentary, for: reader) } label: {
                            MacToolbarLabel(L("Seguir la Biblia de origen"), "link")
                                .foregroundStyle(reader.followsCommentary ? Color.accentColor : Color.primary)
                        }.help(L("Seguir la Biblia de origen"))
                            .accessibilityValue(L(reader.followsCommentary ? "Activado" : "Desactivado"))
                    }
                    Button { workspace.activate(reader); reader.showFind() } label: {
                        MacToolbarLabel(L("Buscar en este recurso"), "magnifyingglass")
                    }.help(L("Buscar en este recurso"))
                    ReaderZoomMenu(reader: reader, activate: { workspace.activate(reader) })
                    Menu {
                        Button(L("Atrás")) { reader.goBack() }.disabled(!reader.canGoBack)
                        Button(L("Adelante")) { reader.goForward() }.disabled(!reader.canGoForward)
                        Button(L("Contenido")) { reader.showsContents.toggle() }
                        Divider()
                        ReaderOutputMenuItems(reader: reader, workspace: workspace)
                    } label: {
                        MacToolbarLabel(L("Acciones de lectura"), "ellipsis")
                    }.menuIndicator(.hidden).help(L("Acciones de lectura"))
                }
            }
        }.padding(.horizontal, 8).frame(height: 44).background(.bar)
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
            highlights: reader.highlights, sourceFontsRevision: reader.sourceFontsRevision,
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
        }.background(Color(nsColor: .underPageBackgroundColor))
    }
}
