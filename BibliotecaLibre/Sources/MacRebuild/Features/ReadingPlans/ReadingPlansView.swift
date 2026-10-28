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

struct ReadingPlansView: View {
    @Bindable var workspace: StudyWorkspace
    @Environment(\.locale) private var locale
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var creating = false
    @RebuildViewState private var deleting = false
    @RebuildViewState private var hideCompleted = false
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
                    Button(L("Eliminar plan…"), role: .destructive) { deleting = true }
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
                List(plan.visibleReadings(hideCompleted: hideCompleted)) { reading in
                    HStack(spacing: 12) {
                        Toggle(L("Completada"), isOn: Binding(get: { currentReading(reading.id)?.completed ?? reading.completed }, set: { setCompleted(reading.id, $0) }))
                            .labelsHidden().accessibilityLabel(L("Completada"))
                        Text(format(reading.day)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                        Text(reading.reference).textSelection(.enabled)
                        Spacer()
                        Button(L("Abrir")) { open(reading) }.disabled(workspace.activeReader?.canSynchronizeBible != true)
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
            .sheet(isPresented: $creating) {
                ReadingPlanCreationView(personal: workspace.personal) { id in selectedID = id }
                    .modifier(AppInterfaceLanguage())
            }
            .alert(L("Borrar plan de lectura"), isPresented: $deleting) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Borrar"), role: .destructive) { remove() }
            } message: { Text(L("Se borrarán el plan y su progreso.")) }
    }
    private func currentReading(_ id: UUID) -> ScheduledReading? { plan?.readings.first { $0.id == id } }
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
