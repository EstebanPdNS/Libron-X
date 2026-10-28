import SwiftUI
import LibronixCore

/// Date selection is independent of the article navigation and never changes
/// a reader until the matching source entry has been checked.
struct DevotionalDateBar: View {
    @Bindable var reader: ReaderSession
    let workspace: StudyWorkspace
    @Environment(\.layoutDirection) private var direction
    @RebuildViewState private var selected = Date()
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = .current
        return value
    }
    var body: some View {
        MacReaderToolbarSurface {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { picker; Spacer(minLength: 4); actions }
                VStack(alignment: .leading, spacing: 8) { picker; actions }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
        .onAppear { alignWithReading() }
        .onChange(of: reader.resource.id) { alignWithReading() }
        .onChange(of: reader.page?.destination.ordinal) { alignWithReading() }
    }
    private var picker: some View {
        DatePicker(L("Fecha"), selection: Binding(get: { selected }, set: { choose($0) }), displayedComponents: .date)
            .datePickerStyle(.field).environment(\.calendar, calendar)
            .help(L("Las lecturas se repiten cada año."))
            .disabled(reader.page == nil)
    }
    private var actions: some View {
        MacReaderControlGroup {
            Button { step(-1) } label: { MacToolbarLabel("Día anterior", direction == .rightToLeft ? "chevron.right" : "chevron.left") }
                .help(L("Día anterior"))
            Button(L("Hoy")) { choose(Date()) }.help(L("Hoy"))
            Button { step(1) } label: { MacToolbarLabel("Día siguiente", direction == .rightToLeft ? "chevron.left" : "chevron.right") }
                .help(L("Día siguiente"))
        }.disabled(reader.page == nil)
    }
    private func choose(_ date: Date) {
        selected = date
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let reading = try? ReadingDay(year: year, month: month, day: day) else {
            reader.error = L("La fecha de lectura no es válida."); return
        }
        workspace.activate(reader); reader.openDevotional(reading)
    }
    private func step(_ count: Int) {
        if let date = calendar.date(byAdding: .day, value: count, to: selected) { choose(date) }
    }
    private func alignWithReading() {
        guard let page = reader.page,
              let directory = try? DevotionalDirectory(entries: page.entries.map { ($0.ordinal, $0.title) }),
              let day = directory.day(forOrdinal: page.destination.ordinal, preferredYear: calendar.component(.year, from: selected)),
              let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) else { return }
        selected = date
    }
}
