import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LibronixCore

private struct ReadingEditRequest: Identifiable {
    let id = UUID()
    let planID: UUID
    let original: ScheduledReading?
}

struct ReadingPlansView: View {
    @Bindable var workspace: StudyWorkspace
    @Environment(\.locale) private var locale
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var creating = false
    @RebuildViewState private var deleting = false
    @RebuildViewState private var hideCompleted = false
    @RebuildViewState private var selectedReading: UUID?
    @RebuildViewState private var editRequest: ReadingEditRequest?
    @RebuildViewState private var deleteReading = false
    @RebuildViewState private var renaming = false
    @RebuildViewState private var titleDraft = ""
    @RebuildViewState private var error: String?
    @RebuildViewState private var navigator = ReadingPlanNavigator()
    @RebuildViewState private var openTask: Task<Void, Never>?
    @RebuildViewState private var openGeneration = 0
    @RebuildViewState private var isOpening = false
    private var bibles: [LibraryResource] {
        let available = workspace.availableResources.filter(KeyLinkKind.bible.supports)
        let ordered = workspace.resourcePriorities.ordered(available, in: .init(kind: .bible))
        let ids = Set(ordered.map(\.id))
        return ordered + available.filter { !ids.contains($0.id) }
    }
    private var editionSelection: Binding<StudyBibleEdition?> {
        Binding(get: { plan?.edition }, set: { edition in
            guard let plan else { return }
            do {
                try workspace.personal.editReadingPlans { state in
                    guard let index = state.plans.firstIndex(where: { $0.id == plan.id }), state.plans[index].edition == plan.edition else {
                        throw PersonalStateError.concurrentChange
                    }
                    state.plans[index].edition = edition
                }
                error = nil
            } catch { self.error = error.localizedDescription }
        })
    }
    private var plan: ReadingPlan? { workspace.personal.readingPlans.plans.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Plan de lectura")).font(.caption).foregroundStyle(.secondary)
                    MacSelectionMenu(L("Plan de lectura"), value: plan?.title ?? L("Selecciona un plan"), selection: $selectedID, fillsWidth: true) {
                        Text(L("Selecciona un plan")).tag(Optional<UUID>.none)
                        ForEach(workspace.personal.readingPlans.plans) { Text($0.title).tag(Optional($0.id)) }
                    }.disabled(isOpening)
                }
                MacReaderControlGroup {
                    MacToolbarButton("Nuevo", "plus") { creating = true }.disabled(isOpening)
                    MacToolbarButton("Exportar calendario…", "square.and.arrow.up", action: export).disabled(plan == nil || isOpening)
                    Menu {
                        Button(L("Renombrar")) { titleDraft = plan?.title ?? ""; renaming = true }
                        Button(L("Eliminar plan…"), role: .destructive) { deleting = true }
                    } label: { Text(L("Acciones")) }.disabled(plan == nil || isOpening)
                }
            }
            if let plan {
                HStack {
                    Toggle(L("Ocultar lecturas completadas"), isOn: $hideCompleted)
                    Spacer()
                    Text(LF("{completed} de {total} lecturas", ["completed": String(plan.readings.filter(\.completed).count), "total": String(plan.readings.count)]))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Biblia")).font(.caption).foregroundStyle(.secondary)
                    MacSelectionMenu(L("Biblia"), value: plan.edition?.resolve(in: bibles)?.title ?? plan.edition?.title ?? L("Biblia activa"), selection: editionSelection, fillsWidth: true) {
                        Text(L("Biblia activa")).tag(Optional<StudyBibleEdition>.none)
                        ForEach(bibles) { Text($0.title).tag(Optional(StudyBibleEdition($0))) }
                        if let saved = plan.edition, saved.resolve(in: bibles) == nil { Text(verbatim: saved.title).tag(Optional(saved)) }
                    }.disabled(isOpening)
                    if let saved = plan.edition, saved.resolve(in: bibles) == nil {
                        Text(LF("Edición guardada no disponible: {edition}. Vuelve a añadirla a la biblioteca o elige otra.", ["edition": saved.title]))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L("Se verifica el inicio del pasaje en la Biblia elegida antes de abrirlo."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if isOpening {
                    HStack { ProgressView().controlSize(.small); Text(L("Verificando pasaje…")).font(.caption); Spacer(); Button(L("Cancelar"), action: cancelOpen) }
                }
                List(plan.visibleReadings(hideCompleted: hideCompleted), selection: $selectedReading) { reading in
                    HStack(spacing: 12) {
                        Toggle(L("Completada"), isOn: Binding(get: { currentReading(reading.id)?.completed ?? reading.completed }, set: { setCompleted(reading.id, $0) }))
                            .labelsHidden().accessibilityLabel(L("Completada"))
                        Text(format(reading.day)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                        Text(reading.reference).textSelection(.enabled)
                        Spacer()
                        Button(L("Abrir")) { open(reading) }.disabled(isOpening || source(for: plan) == nil)
                    }.tag(reading.id)
                }
                MacReaderToolbarSurface {
                    HStack {
                        MacReaderControlGroup {
                            MacToolbarButton("Agregar lectura", "plus") { editRequest = .init(planID: plan.id, original: nil) }.disabled(isOpening)
                            MacToolbarButton("Editar lectura", "pencil") {
                                if let selectedReading, let reading = currentReading(selectedReading) { editRequest = .init(planID: plan.id, original: reading) }
                            }.disabled(isOpening || currentReading(selectedReading ?? UUID()) == nil)
                            MacToolbarButton("Eliminar lectura", "trash") { deleteReading = true }
                                .disabled(isOpening || currentReading(selectedReading ?? UUID()) == nil || plan.readings.count <= 1)
                        }
                        Spacer()
                    }
                }
            } else {
                Spacer()
                Text(L("Crea un plan con pasajes y días de lectura.")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            if let message = error ?? workspace.personal.readingPlansLoadError {
                Text(L(message)).foregroundStyle(.red).font(.caption).textSelection(.enabled)
            }
        }.padding(16)
            .onAppear {
                if let requested = workspace.homeReadingPlanID,
                   workspace.personal.readingPlans.plans.contains(where: { $0.id == requested }) { selectedID = requested }
                else if selectedID == nil { selectedID = workspace.personal.readingPlans.plans.first?.id }
                workspace.homeReadingPlanID = nil
            }
            .onChange(of: selectedID) { selectedReading = nil; cancelOpen() }
            .onChange(of: workspace.availableResources) { cancelOpen() }
            .onDisappear(perform: cancelOpen)
            .sheet(isPresented: $creating) {
                ReadingPlanCreationView(personal: workspace.personal, resources: bibles) { id in selectedID = id }
                    .modifier(AppInterfaceLanguage())
            }
            .sheet(item: $editRequest) { request in
                ReadingEditView(personal: workspace.personal, request: request) { selectedReading = $0 }
                    .modifier(AppInterfaceLanguage())
            }
            .alert(L("Renombrar plan"), isPresented: $renaming) {
                TextField(L("Nombre del plan"), text: $titleDraft)
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Guardar")) { rename() }.disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert(L("Eliminar lectura"), isPresented: $deleteReading) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Borrar"), role: .destructive) { removeReading() }
            } message: { Text(L("Se eliminarán esta lectura y su progreso.")) }
            .alert(L("Borrar plan de lectura"), isPresented: $deleting) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Borrar"), role: .destructive) { remove() }
            } message: { Text(L("Se borrarán el plan y su progreso.")) }
    }
    private func currentReading(_ id: UUID) -> ScheduledReading? { plan?.readings.first { $0.id == id } }
    private func rename() {
        guard let plan else { return }
        do {
            try workspace.personal.editReadingPlans { state in
                guard let index = state.plans.firstIndex(where: { $0.id == plan.id }), state.plans[index] == plan else { throw PersonalStateError.concurrentChange }
                state.plans[index].title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func removeReading() {
        guard let plan, let selectedReading, let original = currentReading(selectedReading) else { return }
        do {
            try workspace.personal.editReadingPlans { state in
                guard let index = state.plans.firstIndex(where: { $0.id == plan.id }), state.plans[index].readings.contains(original),
                      state.plans[index].readings.count > 1 else { throw PersonalStateError.concurrentChange }
                state.plans[index].readings.removeAll { $0.id == original.id }
            }
            self.selectedReading = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func setCompleted(_ id: UUID, _ completed: Bool) {
        guard let selectedID else { return }
        do {
            try workspace.personal.editReadingPlans { state in
                guard let plan = state.plans.firstIndex(where: { $0.id == selectedID }),
                      let item = state.plans[plan].readings.firstIndex(where: { $0.id == id }) else { throw PersonalStateError.invalid("La lectura ya no está disponible.") }
                state.plans[plan].readings[item].completed = completed
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func remove() {
        guard let selectedID else { return }
        do {
            try workspace.personal.editReadingPlans { $0.plans.removeAll { $0.id == selectedID } }
            self.selectedID = workspace.personal.readingPlans.plans.first?.id; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func format(_ day: ReadingDay) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return day.calendarValue }
        let formatter = DateFormatter(); formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
    private func source(for plan: ReadingPlan) -> LibraryResource? {
        if let edition = plan.edition { return edition.resolve(in: bibles) }
        return workspace.activeReader?.canSynchronizeBible == true ? workspace.activeReader?.resource : nil
    }
    private func cancelOpen() {
        openGeneration += 1; openTask?.cancel(); openTask = nil; isOpening = false
    }
    private func open(_ reading: ScheduledReading) {
        guard let plan, let resource = source(for: plan) else { return }
        cancelOpen(); let generation = openGeneration, activeReader = workspace.activeReader
        isOpening = true; error = nil
        openTask = Task {
            do {
                let target = try await navigator.target(reading.reference, in: resource)
                guard generation == openGeneration, !Task.isCancelled else { return }
                isOpening = false; openTask = nil
                guard (plan.edition == nil || workspace.availableResources.contains(resource)),
                      let current = workspace.personal.readingPlans.plans.first(where: { $0.id == plan.id }),
                      current.edition == plan.edition, current.readings.contains(reading),
                      plan.edition != nil || workspace.activeReader === activeReader else { return }
                try LibrarySearchFileStamp.verify(target.sourceStamps)
                let reader: ReaderSession
                if let activeReader, activeReader.resource == resource { reader = activeReader }
                else { reader = workspace.open(resource, startReading: false) }
                reader.load(.init(ordinal: target.verse.sectionOrdinal), selection: target.verse.sourceRange.nsRange,
                    expectedFingerprint: target.verse.sourceFingerprint, expectedSourceStamps: target.sourceStamps)
                workspace.activeTool = nil
            } catch {
                guard generation == openGeneration, !Task.isCancelled else { return }
                isOpening = false; openTask = nil; self.error = error.localizedDescription
            }
        }
    }
    private func export() {
        guard let plan else { return }
        do {
            let bytes = try ReadingPlanCalendar.export(plan)
            let panel = NSSavePanel(); panel.title = L("Exportar calendario")
            panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
            panel.nameFieldStringValue = "Libron-X.ics"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    guard workspace.personal.readingPlans.plans.contains(plan) else { throw PersonalStateError.invalid("El plan cambió. Vuelve a exportarlo.") }
                    try BibliographyExportActions.validateDestination(url, resources: workspace.resources, libraryRoot: workspace.libraryRoot)
                    try bytes.write(to: url, options: .atomic)
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct ReadingEditView: View {
    let personal: WorkspacePersonalState
    let request: ReadingEditRequest
    let saved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var date = Date()
    @RebuildViewState private var reference = ""
    @RebuildViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacToolHeader(title: request.original == nil ? "Agregar lectura" : "Editar lectura") { dismiss() }
            DatePicker(L("Fecha"), selection: $date, displayedComponents: .date)
            TextField(L("Pasaje"), text: $reference).macInputStyle()
            if request.original?.completed == true {
                Text(L("Cambiar el pasaje vuelve a marcar la lectura como pendiente."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(L("Cancelar")) { dismiss() }
                Button(L("Guardar"), action: save).disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(minWidth: 520).modifier(MacPanelControlPresentation())
            .onAppear {
                guard let original = request.original else { return }
                reference = original.reference
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
                date = calendar.date(from: DateComponents(year: original.day.year, month: original.day.month, day: original.day.day, hour: 12)) ?? date
            }
    }
    private func save() {
        do {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else { throw PersonalStateError.invalid("La fecha de lectura no es válida.") }
            let reading = ScheduledReading(id: request.original?.id ?? UUID(), day: try ReadingDay(year: year, month: month, day: day),
                reference: reference.trimmingCharacters(in: .whitespacesAndNewlines), completed: request.original?.completed ?? false)
            try personal.saveScheduledReading(planID: request.planID, original: request.original, replacement: reading)
            saved(reading.id); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct ReadingPlanCreationView: View {
    let personal: WorkspacePersonalState
    let resources: [LibraryResource]
    let created: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @RebuildViewState private var title = ""
    @RebuildViewState private var references = ""
    @RebuildViewState private var start = Date()
    @RebuildViewState private var end = Date().addingTimeInterval(30 * 86_400)
    @RebuildViewState private var weekdays: Set<Int> = Set(1...7)
    @RebuildViewState private var passagesPerDay = 1
    @RebuildViewState private var untilDate = false
    @RebuildViewState private var edition: StudyBibleEdition?
    @RebuildViewState private var error: String?
    @RebuildViewState private var isCreating = false
    @RebuildViewState private var creationTask: Task<Void, Never>?
    private var symbols: [String] {
        let formatter = DateFormatter(); formatter.locale = locale; return formatter.shortWeekdaySymbols
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacToolHeader(title: "Nuevo plan de lectura") { dismiss() }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField(L("Nombre del plan"), text: $title).macInputStyle()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Biblia")).font(.caption).foregroundStyle(.secondary)
                        MacSelectionMenu(L("Biblia"), value: edition?.title ?? L("Biblia activa"), selection: $edition, fillsWidth: true) {
                            Text(L("Biblia activa")).tag(Optional<StudyBibleEdition>.none)
                            ForEach(resources) { Text($0.title).tag(Optional(StudyBibleEdition($0))) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Distribución")).font(.caption).foregroundStyle(.secondary)
                        MacSelectionMenu(L("Distribución"), value: L(untilDate ? "Distribuir hasta una fecha" : "Pasajes por día"), selection: $untilDate, fillsWidth: true) {
                            Text(L("Pasajes por día")).tag(false)
                            Text(L("Distribuir hasta una fecha")).tag(true)
                        }
                    }
                    DatePicker(L("Fecha de inicio"), selection: $start, displayedComponents: .date)
                    if untilDate {
                        DatePicker(L("Fecha final"), selection: $end, displayedComponents: .date)
                        Text(L("Los pasajes se reparten de forma equilibrada entre los días elegidos, conservando su orden."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Pasajes por día")).font(.caption).foregroundStyle(.secondary)
                            MacSelectionMenu(L("Pasajes por día"), value: String(passagesPerDay), selection: $passagesPerDay, fillsWidth: true) {
                                ForEach(1...10, id: \.self) { Text(String($0)).tag($0) }
                            }
                        }
                    }
                    Text(L("Días de lectura")).font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 10) {
                        ForEach(1...7, id: \.self) { day in
                            Toggle(symbols[day - 1], isOn: Binding(get: { weekdays.contains(day) }, set: { value in
                                if value { weekdays.insert(day) } else { weekdays.remove(day) }
                            }))
                        }
                    }
                    Text(L("Un pasaje por línea"))
                    TextEditor(text: $references).scrollContentBackground(.hidden).padding(8).frame(height: 130)
                        .macEditorSurface().accessibilityLabel(L("Pasajes"))
                }.padding(20).disabled(isCreating)
            }
            Divider()
            if let error { Text(L(error)).foregroundStyle(.red).font(.caption).textSelection(.enabled).padding(.horizontal, 20).padding(.top, 12) }
            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Cancelar")) { dismiss() }
                Button(L("Crear"), action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || references.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || weekdays.isEmpty)
            }.padding(20)
        }.frame(width: 600, height: min(700, max(520, (NSScreen.main?.visibleFrame.height ?? 800) - 100)))
            .modifier(MacPanelControlPresentation())
            .onDisappear { creationTask?.cancel() }
    }
    private func create() {
        do {
            let passages = references.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let first = try day(start), last = untilDate ? try day(end) : nil
            let name = title, days = weekdays, count = passagesPerDay, chosenEdition = edition
            isCreating = true; error = nil
            creationTask = Task {
                let worker = Task.detached(priority: .userInitiated) {
                    var plan: ReadingPlan
                    if let last { plan = try ReadingPlan.schedule(title: name, references: passages, start: first, end: last, weekdays: days) }
                    else { plan = try ReadingPlan.schedule(title: name, references: passages, start: first, weekdays: days, passagesPerDay: count) }
                    plan.edition = chosenEdition
                    return plan
                }
                do {
                    let plan = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    try personal.editReadingPlans { $0.plans.append(plan) }
                    created(plan.id); dismiss()
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                isCreating = false; creationTask = nil
            }
        } catch { self.error = error.localizedDescription }
    }
    private func day(_ date: Date) throws -> ReadingDay {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { throw PersonalStateError.invalid("La fecha de lectura no es válida.") }
        return try ReadingDay(year: year, month: month, day: day)
    }
}
