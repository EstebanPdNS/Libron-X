import SwiftUI

/// The palette exposes existing workspace tools without creating parallel actions.
struct WorkspacePaletteCommand: Identifiable {
    let tool: WorkspaceTool
    let title: String
    let symbol: String
    var id: String { tool.rawValue }

    static let all: [Self] = [
        .init(tool: .search, title: "Búsqueda básica…", symbol: "magnifyingglass"),
        .init(tool: .referenceSearch, title: "Buscar referencias bíblicas", symbol: "text.book.closed"),
        .init(tool: .annotationSearch, title: "Buscar notas y resaltados", symbol: "text.magnifyingglass"),
        .init(tool: .topics, title: "Explorador temático", symbol: "tag"),
        .init(tool: .passageGuide, title: "Guía de pasajes", symbol: "book"),
        .init(tool: .readingPlans, title: "Planes de lectura", symbol: "calendar"),
        .init(tool: .prayerJournal, title: "Lista de oración", symbol: "list.bullet"),
        .init(tool: .scriptureMemory, title: "Memorización de pasajes", symbol: "brain"),
        .init(tool: .studyAssessments, title: "Autoevaluaciones", symbol: "checklist"),
        .init(tool: .wordSearch, title: "Sopa de letras", symbol: "square.grid.3x3"),
        .init(tool: .biblicalMeasures, title: "Pesos y medidas bíblicos", symbol: "scalemass"),
        .init(tool: .researchInbox, title: "Bandeja de investigación", symbol: "tray"),
        .init(tool: .transliteration, title: "Transliteración", symbol: "character.book.closed"),
        .init(tool: .passageComparison, title: "Comparar pasajes bíblicos", symbol: "rectangle.split.2x1"),
        .init(tool: .keyLinks, title: "Enlaces clave", symbol: "link"),
        .init(tool: .associations, title: "Asociaciones de recursos", symbol: "link"),
        .init(tool: .bibliography, title: "Bibliografía", symbol: "books.vertical"),
        .init(tool: .editions, title: "Duplicados y ediciones", symbol: "doc.on.doc"),
        .init(tool: .bibleCopy, title: "Copiar versículos bíblicos", symbol: "doc.on.clipboard"),
        .init(tool: .documents, title: "Documentos de estudio", symbol: "note.text"),
        .init(tool: .resources, title: "Recursos y licencias", symbol: "externaldrive"),
        .init(tool: .favorites, title: "Favoritos", symbol: "star"),
        .init(tool: .windows, title: "Ventanas", symbol: "macwindow"),
        .init(tool: .parallelSets, title: "Grupos de Biblias paralelas", symbol: "rectangle.split.2x1"),
    ]
    @MainActor static func matching(_ query: String) -> [Self] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return all }
        return all.filter { L($0.title).range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

struct WorkspaceCommandPaletteView: View {
    @Bindable var workspace: StudyWorkspace
    @RebuildViewState private var query = ""
    @RebuildViewState private var selection: String?
    @FocusState private var searchFocused: Bool
    private var commands: [WorkspacePaletteCommand] { WorkspacePaletteCommand.matching(query) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(L("Buscar un comando"), text: $query).macInputStyle().focused($searchFocused)
                .onSubmit { openSelected() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            List(commands, selection: $selection) { command in
                Button { open(command) } label: { Label(L(command.title), systemImage: command.symbol).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).tag(command.id)
            }
            .overlay { if commands.isEmpty { Text(L("No hay comandos coincidentes.")).foregroundStyle(.secondary) } }
            HStack {
                Text(L("Usa las flechas y pulsa Intro para abrir.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Abrir")) { openSelected() }.disabled(commands.isEmpty)
            }
        }.padding(16).onAppear { searchFocused = true }
            .onChange(of: query) { selection = commands.first?.id }
    }
    private func openSelected() {
        guard let command = commands.first(where: { $0.id == selection }) ?? commands.first else { return }
        open(command)
    }
    private func move(_ delta: Int) {
        guard !commands.isEmpty else { return }
        let index = commands.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : commands.count)
        selection = commands[min(max(index + delta, 0), commands.count - 1)].id
    }
    private func open(_ command: WorkspacePaletteCommand) {
        if command.tool == .search { workspace.beginSearch() }
        else if command.tool == .referenceSearch { workspace.beginReferenceSearch() }
        else { workspace.activeTool = command.tool }
    }
}
