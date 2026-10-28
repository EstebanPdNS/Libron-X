import SwiftUI
import LibronixCore

private enum PrayerDates {
    static var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = .current; return value }
    static func day(_ date: Date) throws -> ReadingDay {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { throw PersonalStateError.invalid("La fecha de lectura no es válida.") }
        return try ReadingDay(year: year, month: month, day: day)
    }
    static func date(_ day: ReadingDay) -> Date? {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
    }
}
private struct PrayerEditRequest: Identifiable {
    let id = UUID()
    let original: PrayerRequest?
}

struct PrayerJournalView: View {
    @Bindable var personal: WorkspacePersonalState
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var categoryID: UUID?
    @RebuildViewState private var date = Date()
    @RebuildViewState private var showPrivate = false
    @RebuildViewState private var dueOnly = false
    @RebuildViewState private var edit: PrayerEditRequest?
    @RebuildViewState private var categoriesOpen = false
    @RebuildViewState private var deleting = false
    @RebuildViewState private var error: String?
    private var selected: PrayerRequest? { personal.prayerJournal.requests.first { $0.id == selectedID } }
    private var canShowSelected: Bool {
        guard let selected, !selected.isPrivate || showPrivate else { return false }
        return visible.contains { $0.id == selected.id }
    }
    private var day: ReadingDay? { try? PrayerDates.day(date) }
    private var visible: [PrayerRequest] {
        personal.prayerJournal.requests.filter { request in
            (categoryID == nil || request.categoryID == categoryID) &&
            (!dueOnly || day.map { (try? request.isDue(on: $0)) == true } == true)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker(L("Categoría"), selection: $categoryID) {
                    Text(L("Todas las categorías")).tag(Optional<UUID>.none)
                    ForEach(personal.prayerJournal.categories) { Text($0.name).tag(Optional($0.id)) }
                }
                Button(L("Categorías…")) { categoriesOpen = true }
                Spacer(minLength: 8)
                DatePicker(L("Fecha"), selection: $date, displayedComponents: .date).datePickerStyle(.field)
                    .environment(\.calendar, PrayerDates.calendar)
            }
            HStack {
                Toggle(L("Solo pendientes"), isOn: $dueOnly)
                Toggle(L("Mostrar privadas"), isOn: $showPrivate)
                Spacer()
            }
            Text(L("Las oraciones se guardan localmente. Ocultar una oración no cifra el archivo."))
                .font(.caption).foregroundStyle(.secondary)
            List(visible, selection: $selectedID) { request in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.isPrivate && !showPrivate ? L("Oración privada") : request.title).font(.headline)
                        if !request.isPrivate || showPrivate {
                            HStack {
                                if let category = personal.prayerJournal.categories.first(where: { $0.id == request.categoryID }) { Text(category.name) }
                                Text(L(request.answered == nil ? "Pendiente" : "Respondida"))
                                if let day, (try? request.isDue(on: day)) == true { Text(L("Para esta fecha")) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if request.isPrivate { Image(systemName: "eye.slash").accessibilityLabel(L("Privada")) }
                }.tag(request.id)
            }
            .overlay {
                if visible.isEmpty { Text(L("No hay oraciones en esta vista.")).foregroundStyle(.secondary).allowsHitTesting(false) }
            }
            if let request = selected, canShowSelected, !request.details.isEmpty {
                ScrollView { Text(request.details).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 90)
            }
            MacReaderToolbarSurface {
                HStack {
                    MacReaderControlGroup {
                        MacToolbarButton("Añadir oración", "plus") { edit = .init(original: nil) }
                        MacToolbarButton("Editar oración", "pencil") { if canShowSelected { edit = .init(original: selected) } }
                            .disabled(!canShowSelected)
                        MacToolbarButton("Eliminar oración", "trash") { deleting = true }.disabled(!canShowSelected)
                    }
                    Spacer()
                    if let request = selected, canShowSelected {
                        Button(L("Marcar oración hecha")) { markPrayed(request) }
                            .disabled(day.map { (try? request.isDue(on: $0)) != true } ?? true)
                        Button(L(request.answered == nil ? "Marcar respondida" : "Reabrir oración")) { toggleAnswered(request) }
                    }
                }
            }
            if let error = error ?? personal.prayerJournalLoadError { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(16)
            .onChange(of: showPrivate) { if !showPrivate, selected?.isPrivate == true { selectedID = nil } }
            .onChange(of: categoryID) { selectedID = nil }
            .onChange(of: dueOnly) { selectedID = nil }
            .onChange(of: date) { selectedID = nil }
            .sheet(item: $edit) { value in
                PrayerEditor(personal: personal, original: value.original) { selectedID = $0 }
                    .modifier(AppInterfaceLanguage())
            }
            .sheet(isPresented: $categoriesOpen) { PrayerCategoriesView(personal: personal).modifier(AppInterfaceLanguage()) }
            .alert(L("Eliminar oración"), isPresented: $deleting) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Eliminar"), role: .destructive) { removeSelected() }
            } message: { Text(L("Se eliminará esta oración.")) }
    }
    private func markPrayed(_ original: PrayerRequest) {
        guard let day else { return }
        do { var next = original; try next.markPrayed(on: day); try personal.savePrayerRequest(original: original, replacement: next); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func toggleAnswered(_ original: PrayerRequest) {
        guard let day else { return }
        do { var next = original; try next.setAnswered(on: original.answered == nil ? day : nil); try personal.savePrayerRequest(original: original, replacement: next); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func removeSelected() {
        guard let original = selected, canShowSelected else { return }
        do {
            try personal.editPrayerJournal { journal in
                guard journal.requests.contains(original) else { throw PersonalStateError.concurrentChange }
                journal.requests.removeAll { $0.id == original.id }
            }
            selectedID = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct PrayerEditor: View {
    @Bindable var personal: WorkspacePersonalState
    let original: PrayerRequest?
    let saved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var title = ""
    @RebuildViewState private var details = ""
    @RebuildViewState private var category: UUID?
    @RebuildViewState private var date = Date()
    @RebuildViewState private var repetition: PrayerRepeat = .once
    @RebuildViewState private var isPrivate = false
    @RebuildViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: original == nil ? "Añadir oración" : "Editar oración") { dismiss() }
            TextField(L("Título"), text: $title).macInputStyle()
            Text(L("Detalles"))
            TextEditor(text: $details).scrollContentBackground(.hidden).padding(8).frame(minHeight: 120)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
            Picker(L("Categoría"), selection: $category) {
                Text(L("Sin categoría")).tag(Optional<UUID>.none)
                ForEach(personal.prayerJournal.categories) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker(L("Repetición"), selection: $repetition) {
                Text(L("Una vez")).tag(PrayerRepeat.once)
                Text(L("Diaria")).tag(PrayerRepeat.daily)
                Text(L("Semanal")).tag(PrayerRepeat.weekly)
                Text(L("Mensual")).tag(PrayerRepeat.monthly)
            }
            DatePicker(L("Fecha de inicio"), selection: $date, displayedComponents: .date)
                .datePickerStyle(.field).environment(\.calendar, PrayerDates.calendar)
            Toggle(L("Privada"), isOn: $isPrivate)
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button(L("Cancelar")) { dismiss() }; Button(L("Guardar"), action: save).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(16).frame(width: 520).modifier(MacPanelControlPresentation())
            .onAppear {
                guard let original else { return }
                title = original.title; details = original.details; category = original.categoryID
                date = PrayerDates.date(original.start) ?? date; repetition = original.repetition; isPrivate = original.isPrivate
            }
    }
    private func save() {
        do {
            let day = try PrayerDates.day(date)
            var value = original ?? PrayerRequest(title: "", start: day)
            value.title = title.trimmingCharacters(in: .whitespacesAndNewlines); value.details = details
            value.categoryID = category; value.start = day; value.repetition = repetition; value.isPrivate = isPrivate
            try personal.savePrayerRequest(original: original, replacement: value)
            saved(value.id); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct PrayerCategoriesView: View {
    @Bindable var personal: WorkspacePersonalState
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var name = ""
    @RebuildViewState private var removing = false
    @RebuildViewState private var error: String?
    private var selected: PrayerCategory? { personal.prayerJournal.categories.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Categorías de oración") { dismiss() }
            List(personal.prayerJournal.categories, selection: $selectedID) { category in Text(category.name).tag(category.id) }
                .overlay {
                    if personal.prayerJournal.categories.isEmpty { Text(L("No hay categorías de oración.")).foregroundStyle(.secondary).allowsHitTesting(false) }
                }
            TextField(L("Nombre de categoría"), text: $name).macInputStyle()
            HStack {
                Button(L("Añadir categoría"), action: add).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L("Renombrar"), action: rename).disabled(selected == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L("Eliminar categoría…")) { removing = true }.disabled(selected == nil)
                Spacer()
            }
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(16).frame(width: 540, height: 420).modifier(MacPanelControlPresentation())
            .onChange(of: selectedID) { name = selected?.name ?? "" }
            .alert(L("Eliminar categoría"), isPresented: $removing) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Eliminar"), role: .destructive) { remove() }
            } message: { Text(L("Solo se pueden eliminar categorías sin oraciones.")) }
    }
    private func add() {
        do {
            let category = PrayerCategory(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            try personal.editPrayerJournal { $0.categories.append(category) }
            selectedID = category.id; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func rename() {
        guard let original = selected else { return }
        do {
            try personal.editPrayerJournal { journal in
                guard let index = journal.categories.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                journal.categories[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func remove() {
        guard let original = selected else { return }
        do {
            try personal.editPrayerJournal { journal in
                guard journal.categories.contains(original) else { throw PersonalStateError.concurrentChange }
                try journal.removeCategory(original.id)
            }
            selectedID = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
