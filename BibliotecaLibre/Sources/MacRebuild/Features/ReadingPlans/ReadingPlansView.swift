import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LibronixCore

enum ReadingPlanNavigation {
    /// Navigate to the first address; a range remains scheduled in full.
    /// Edition-qualified references cannot silently target the active edition.
    static func start(_ reference: String) -> String? {
        guard let query = try? BibleReferenceQuery.parse(reference),
              query.citations.allSatisfy({ $0.edition == nil }),
              let address = query.citations.first?.spans.first?.lower else { return nil }
        let target = "\(address.book) \(max(1, address.chapter)):\(max(1, address.verse))"
        return LegacyPassageQuery.navigationInput(target)?.displayReference
    }
}

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
    private var plan: ReadingPlan? { workspace.personal.readingPlans.plans.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker(L("Plan de lectura"), selection: $selectedID) {
                    Text(L("Selecciona un plan")).tag(Optional<UUID>.none)
                    ForEach(workspace.personal.readingPlans.plans) { Text($0.title).tag(Optional($0.id)) }
                }
                Button(L("Nuevo")) { creating = true }
                if plan != nil {
                    Button(L("Exportar calendario…"), action: export)
                    Menu(L("Acciones")) {
                        Button(L("Renombrar")) { titleDraft = plan?.title ?? ""; renaming = true }
                        Button(L("Eliminar plan…"), role: .destructive) { deleting = true }
                    }
                }
            }
            if let plan {
                HStack {
                    Toggle(L("Ocultar lecturas completadas"), isOn: $hideCompleted)
                    Spacer()
                    Text(LF("{completed} de {total} lecturas", ["completed": String(plan.readings.filter(\.completed).count), "total": String(plan.readings.count)]))
                        .foregroundStyle(.secondary)
                }
                Text(L("Las lecturas se abren al principio del pasaje en la Biblia activa."))
                    .font(.caption).foregroundStyle(.secondary)
                List(plan.visibleReadings(hideCompleted: hideCompleted), selection: $selectedReading) { reading in
                    HStack(spacing: 12) {
                        Toggle(L("Completada"), isOn: Binding(get: { currentReading(reading.id)?.completed ?? reading.completed }, set: { setCompleted(reading.id, $0) }))
                            .labelsHidden().accessibilityLabel(L("Completada"))
                        Text(format(reading.day)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                        Text(reading.reference).textSelection(.enabled)
                        Spacer()
                        Button(L("Abrir")) { open(reading) }.disabled(workspace.activeReader?.canSynchronizeBible != true)
                    }.tag(reading.id)
                }
                MacReaderToolbarSurface {
                    HStack {
                        MacReaderControlGroup {
                            MacToolbarButton("Agregar lectura", "plus") { editRequest = .init(planID: plan.id, original: nil) }
                            MacToolbarButton("Editar lectura", "pencil") {
                                if let selectedReading, let reading = currentReading(selectedReading) { editRequest = .init(planID: plan.id, original: reading) }
                            }.disabled(currentReading(selectedReading ?? UUID()) == nil)
                            MacToolbarButton("Eliminar lectura", "trash") { deleteReading = true }
                                .disabled(currentReading(selectedReading ?? UUID()) == nil || plan.readings.count <= 1)
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
            .onAppear { if selectedID == nil { selectedID = workspace.personal.readingPlans.plans.first?.id } }
            .onChange(of: selectedID) { selectedReading = nil }
            .sheet(isPresented: $creating) {
                ReadingPlanCreationView(personal: workspace.personal) { id in selectedID = id }
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
    private func open(_ reading: ScheduledReading) {
        guard let reader = workspace.activeReader, reader.canSynchronizeBible else { return }
        guard let target = ReadingPlanNavigation.start(reading.reference) else {
            error = L("Esta referencia no se puede abrir directamente. Revísala en la Biblia."); return
        }
        reader.changeLocatorMode(false); reader.locator = target; reader.goToReference()
        workspace.activeTool = nil
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
    let created: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @RebuildViewState private var title = ""
    @RebuildViewState private var references = ""
    @RebuildViewState private var start = Date()
    @RebuildViewState private var weekdays: Set<Int> = Set(1...7)
    @RebuildViewState private var error: String?
    private var symbols: [String] {
        let formatter = DateFormatter(); formatter.locale = locale; return formatter.shortWeekdaySymbols
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacToolHeader(title: "Nuevo plan de lectura") { dismiss() }
            TextField(L("Nombre del plan"), text: $title).macInputStyle()
            DatePicker(L("Fecha de inicio"), selection: $start, displayedComponents: .date)
            Text(L("Días de lectura")).font(.headline)
            HStack(spacing: 10) {
                ForEach(1...7, id: \.self) { day in
                    Toggle(symbols[day - 1], isOn: Binding(get: { weekdays.contains(day) }, set: { value in
                        if value { weekdays.insert(day) } else { weekdays.remove(day) }
                    }))
                }
            }
            Text(L("Un pasaje por línea"))
            TextEditor(text: $references).frame(minHeight: 100, idealHeight: 130, maxHeight: 180)
                .accessibilityLabel(L("Pasajes"))
            if let error { Text(L(error)).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(L("Cancelar")) { dismiss() }
                Button(L("Crear"), action: create)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || references.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || weekdays.isEmpty)
            }
        }.padding(20).frame(minWidth: 600).modifier(MacPanelControlPresentation())
    }
    private func create() {
        do {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { throw PersonalStateError.invalid("La fecha de lectura no es válida.") }
            let passages = references.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let plan = try ReadingPlan.schedule(title: title, references: passages, start: ReadingDay(year: year, month: month, day: day), weekdays: weekdays)
            try personal.editReadingPlans { $0.plans.append(plan) }
            created(plan.id); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
