import LibronixCore
import SwiftUI

enum LibraryPalette {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.48, green: 0.74, blue: 0.66, alpha: 1)
            : NSColor(red: 0.24, green: 0.43, blue: 0.38, alpha: 1)
    })
    static let brand = Color(red: 0.76, green: 0.16, blue: 0.19)
    static let paper = Color(nsColor: .textBackgroundColor)
}

struct LibraryWorkspace: View {
    @Bindable var model: LibraryModel
    @FocusState private var searchIsFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } content: {
            Group {
                if model.section == .documents { StudyDocumentsCatalog(model: model) }
                else { catalog }
            }.navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 560)
        } detail: {
            if model.section == .search {
                LibrarySearchWorkspace(model: model.bookSearch, resources: model.resources, selectedResource: model.selectedResource, openResult: model.openSearchResult)
            } else if model.section == .collections {
                CollectionsExplorer(snapshot: model.metadata)
            } else if model.section == .favorites {
                FavoritesWorkspace(model: model)
            } else if model.section == .documents {
                StudyDocumentsWorkspace(model: model)
            } else if let resource = model.selectedResource {
                ResourceWorkspace(resource: resource, reader: model.reader, linkGroup: $model.linkGroup,
                    annotations: model.readerAnnotations, openAnnotation: model.openAnnotation, reveal: { model.reveal(resource) })
            } else {
                welcome
            }
        }
        .tint(LibraryPalette.accent)
        .background(LibraryWindowAttachment { model.attachWindow($0) }.frame(width: 0, height: 0))
        .alert("Destino no disponible", isPresented: Binding(get: { model.destinationError != nil }, set: { if !$0 { model.destinationError = nil } })) {
            Button("Aceptar", role: .cancel) { model.destinationError = nil }
        } message: { Text(model.destinationError ?? "") }
        .onChange(of: model.searchFocusRequest) { _, _ in searchIsFocused = true }
        .sheet(isPresented:Binding(get:{model.output.showsPreview},set:{model.output.showsPreview = $0})) {
            ReaderOutputPreview(output:model.output,window:model.window)
        }
        .sheet(isPresented:Binding(get:{model.bibleCopy.isPresented},set:{model.bibleCopy.isPresented = $0})) {
            BibleCopyWorkspace(model:model.bibleCopy,resources:model.resources)
        }
        .sheet(isPresented:Binding(get:{model.output.showsPageSetup && !model.output.showsPreview},set:{model.output.showsPageSetup = $0})) {
            ReaderPageSetup(output:model.output)
        }
        .alert("No se pudo preparar la salida",isPresented:Binding(get:{model.output.errorMessage != nil},set:{if !$0 { model.output.errorMessage = nil }})) {
            Button("Aceptar",role:.cancel) { model.output.errorMessage = nil }
        } message: { Text(model.output.errorMessage ?? "") }
        .toolbar {
            ToolbarItem(placement:.automatic) {
                Button(action:model.openBibleCopy) { Label("Copiar versículos",systemImage:"doc.on.clipboard") }
                    .disabled(!model.resources.contains(where:{$0.format == .legacyLSF && !$0.isHelp}))
            }
            ToolbarItem(placement:.automatic) {
                Menu {
                    Button("Vista previa de impresión") { model.prepareOutput(.preview) }
                    Button("Imprimir…") { model.prepareOutput(.printReading) }
                    Button("Exportar…") { model.prepareOutput(.export) }
                    Divider()
                    Button("Vista previa de la selección") { model.prepareOutput(.previewSelection) }
                        .disabled((model.reader.selectedTextRange?.length ?? 0) == 0)
                    Button("Imprimir selección…") { model.prepareOutput(.printSelection) }
                        .disabled((model.reader.selectedTextRange?.length ?? 0) == 0)
                    Divider()
                    Button("Configurar página…") { model.output.showsPageSetup = true }
                } label: { Label("Salida del lector",systemImage:"printer") }
                .disabled(!model.canPrepareOutput || model.output.isPreparing)
            }
            ToolbarItem(placement: .automatic) {
                Button(action: model.chooseLibrary) { Label("Abrir biblioteca", systemImage: "folder.badge.plus") }
                    .help("Abrir una carpeta de recursos · ⇧⌘O")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: model.reload) { Label("Actualizar catálogo", systemImage: "arrow.clockwise") }
                    .disabled(model.snapshot == nil || model.isImporting)
            }
        }
        .overlay(alignment: .bottom) {
            if model.isImporting { importProgress }
            else if model.output.isPreparing {
                HStack { ProgressView().controlSize(.small); Text("Preparando la salida…"); Button("Cancelar",action:model.output.cancelPreparation) }
                    .padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).padding()
            }
        }
        .alert("No se pudo abrir la biblioteca", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("Aceptar", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandMark().frame(width: 30, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LIBRON-X").font(.system(size: 15, weight: .bold, design: .serif)).tracking(1.4)
                    Text("BIBLIOTECA DIGITAL").font(.system(size: 8, weight: .medium)).tracking(1.4).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 23).padding(.top, 28).padding(.bottom, 35)
            Text("TU BIBLIOTECA").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                .foregroundStyle(.secondary).padding(.horizontal, 23).padding(.bottom, 12)
            List(selection: Binding<LibrarySection?>(
                get: { model.section }, set: { model.section = $0 ?? .all })) {
                ForEach(LibrarySection.allCases) { section in
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol).frame(width: 20)
                        Text(section.title).font(.system(size: 12.5, weight: model.section == section ? .semibold : .regular))
                        Spacer(minLength: 2)
                        Text(model.count(for: section), format: .number).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                    .tag(section)
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Label("Guardada en tu Mac", systemImage: "externaldrive")
                    .font(.system(size: 11, weight: .medium))
                Text(model.snapshot?.root.lastPathComponent ?? "Elige tu carpeta para comenzar")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Button("Abrir otra biblioteca…", action: model.chooseLibrary)
                    .buttonStyle(.link).font(.system(size: 11))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            .padding(12)
        }
    }

    private var catalog: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Colección").font(.system(size: 29, weight: .medium, design: .serif))
                    Spacer()
                    Text("\(model.visibleResources.count) recursos").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar título, autor o archivo", text: $model.searchText)
                        .textFieldStyle(.plain).font(.system(size: 13)).focused($searchIsFocused)
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain).accessibilityLabel("Borrar búsqueda")
                    }
                }
                .padding(11).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 7) {
                    formatChip("Todo", format: nil)
                    formatChip("LSF", format: .legacyLSF)
                    formatChip("LLS", format: .libronixLLS)
                    formatChip("OEB", format: .libronixOEB)
                    Spacer(minLength: 0)
                    Picker("Ordenar catálogo", selection: $model.sort) {
                        ForEach(CatalogSort.allCases) { sort in Text(sort.title).tag(sort) }
                    }.labelsHidden().frame(width: 94).controlSize(.small)
                }
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20)
            Divider()
            if model.visibleResources.isEmpty {
                ContentUnavailableView(model.resources.isEmpty ? "Tu colección comienza aquí" : "Sin coincidencias",
                    systemImage: model.resources.isEmpty ? "books.vertical" : "magnifyingglass",
                    description: Text(model.resources.isEmpty ? "Abre la carpeta de tus recursos Libronix." : "Prueba otro título, autor o formato."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.visibleResources) { resource in
                        CatalogRow(resource: resource).tag(resource.id)
                            .contextMenu {
                                Button("Abrir en nueva ventana") { openWindow(id: "resource", value: resource.id) }
                                Button("Mostrar en Finder") { model.reveal(resource) }
                            }
                            .listRowSeparator(.hidden)
                            .padding(.vertical, 5)
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
            }
            Divider()
            HStack(spacing: 6) {
                Circle().fill(LibraryPalette.accent).frame(width: 5, height: 5)
                Text(model.isImporting ? "Leyendo tu biblioteca…" : "Archivos originales conservados")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(LibraryPalette.paper)
    }

    private func formatChip(_ title: String, format: ResourceFormat?) -> some View {
        Button { model.format = format } label: {
            Text(title).font(.system(size: 10, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(model.format == format ? LibraryPalette.accent : .secondary)
                .background(model.format == format ? LibraryPalette.accent.opacity(0.12) : .clear,
                    in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Image(systemName: "books.vertical.fill").font(.system(size: 65, weight: .ultraLight))
                .foregroundStyle(LibraryPalette.accent.opacity(0.8))
            Text("Un nuevo hogar\npara tu biblioteca.")
                .font(.system(size: 42, weight: .regular, design: .serif)).multilineTextAlignment(.center)
            Text("Conserva tu colección. Descubre sus recursos.\nEmpieza eligiendo la carpeta de tus libros.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            Button("Abrir biblioteca…", action: model.chooseLibrary)
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 5)
            Text("Tus archivos permanecen en su ubicación original.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }.padding(50).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var importProgress: some View {
        HStack(spacing: 15) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text("Abriendo tu biblioteca").font(.system(size: 12, weight: .semibold))
                if let progress = model.progress {
                    Text("\(progress.completed) de \(progress.total) recursos").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Button("Cancelar", action: model.cancelImport).buttonStyle(.bordered)
        }
        .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 5).padding(.bottom, 22)
    }
}

private struct CatalogRow: View {
    let resource: LibraryResource
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            BookCover(resource: resource, compact: true).frame(width: 44, height: 60)
            VStack(alignment: .leading, spacing: 5) {
                Text(resource.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text(resource.author ?? resource.fileName).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 5) {
                    Text(resource.format.displayName).font(.system(size: 9, weight: .medium))
                    if resource.provenance == .legacyPublicMetadata {
                        Circle().frame(width: 3, height: 3)
                        Text("Título recuperado").font(.system(size: 9))
                    }
                }.foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct BookCover: View {
    let resource: LibraryResource
    var compact = false
    private var color: Color {
        switch resource.format {
        case .legacyLSF: Color(red: 0.25, green: 0.41, blue: 0.36)
        case .libronixLLS: Color(red: 0.30, green: 0.35, blue: 0.43)
        case .eSwordSQLite, .epub, .logosModern, .libronDictionary: Color.gray
        case .libronixOEB: Color(red: 0.51, green: 0.37, blue: 0.29)
        }
    }
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: compact ? 3 : 7).fill(color.gradient)
            Rectangle().fill(.black.opacity(0.18)).frame(width: compact ? 4 : 10).padding(.leading, compact ? 2 : 5)
            VStack(spacing: compact ? 6 : 22) {
                Image(systemName: resource.isHelp ? "sparkle" : "book")
                    .font(.system(size: compact ? 13 : 28, weight: .ultraLight))
                if !compact {
                    Text(resource.title).font(.system(size: 20, weight: .medium, design: .serif))
                        .multilineTextAlignment(.center).lineLimit(5).minimumScaleFactor(0.6)
                }
                Rectangle().frame(width: compact ? 15 : 40, height: 1).opacity(0.4)
            }
            .foregroundStyle(Color(red: 0.95, green: 0.90, blue: 0.77))
            .padding(compact ? 6 : 23).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .shadow(color: .black.opacity(compact ? 0.12 : 0.2), radius: compact ? 2 : 15, x: 2, y: compact ? 2 : 10)
        .accessibilityHidden(true)
    }
}
