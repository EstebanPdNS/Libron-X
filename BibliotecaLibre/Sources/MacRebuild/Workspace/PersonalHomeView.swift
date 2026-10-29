import SwiftUI
import LibronixCore

struct HomeScheduledReading: Identifiable {
    let plan: ReadingPlan
    let reading: ScheduledReading
    var id: UUID { reading.id }
}

enum PersonalHomeSummary {
    static func today(plans: [ReadingPlan], date: Date, timeZone: TimeZone) -> [HomeScheduledReading] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let today = try? ReadingDay(year: year, month: month, day: day) else { return [] }
        return plans.flatMap { plan in plan.readings.filter { $0.day == today }.map { HomeScheduledReading(plan: plan, reading: $0) } }
    }
}

struct PersonalHomeView: View {
    @Bindable var workspace: StudyWorkspace
    let openLibrary: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let today = PersonalHomeSummary.today(plans: workspace.personal.readingPlans.plans, date: context.date, timeZone: .current)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Label(L("Espacio de trabajo"), systemImage: "books.vertical").font(.title2.weight(.semibold))
                        Spacer()
                        Button(L("Abrir Mi biblioteca"), action: openLibrary)
                    }
                    if let reader = workspace.activeReader {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Continuar lectura")).font(.headline)
                            Button { workspace.activate(reader) } label: {
                                Label(reader.resource.title, systemImage: "book")
                            }.help(reader.currentReference ?? reader.resource.title)
                            if let reference = reader.currentReference, !reference.isEmpty {
                                Text(reference).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).macEditorSurface()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(L("Lecturas de hoy")).font(.headline)
                            Spacer()
                            Button(L("Planes de lectura")) { workspace.homeReadingPlanID = nil; workspace.activeTool = .readingPlans }
                        }
                        if let error = workspace.personal.readingPlansLoadError {
                            Text(L(error)).foregroundStyle(.red).textSelection(.enabled)
                        } else if today.isEmpty { Text(L("No hay lecturas programadas para hoy.")).foregroundStyle(.secondary) }
                        ForEach(Array(today.prefix(5))) { item in
                            Button {
                                workspace.homeReadingPlanID = item.plan.id; workspace.activeTool = .readingPlans
                            } label: {
                                HStack {
                                    Image(systemName: item.reading.completed ? "checkmark.circle.fill" : "circle")
                                    Text(item.reading.reference)
                                    Spacer()
                                    Text(item.plan.title).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                        if today.count > 5 { Text(LF("{count} lecturas más", ["count": String(today.count - 5)])).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16).macEditorSurface()
                    if !workspace.personal.documents.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("Documentos de estudio")).font(.headline)
                            ForEach(Array(workspace.personal.documents.prefix(5))) { document in
                                Button {
                                    workspace.personal.selectedDocumentID = document.id; workspace.activeTool = .documents
                                } label: { Label(document.title, systemImage: document.kind == .notebook ? "note.text" : "list.bullet") }
                            }
                            if workspace.personal.documents.count > 5 {
                                Button(L("Documentos de estudio")) { workspace.activeTool = .documents }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).macEditorSurface()
                    }
                    if let error = workspace.personal.loadError {
                        Text(L(error)).foregroundStyle(.red).textSelection(.enabled)
                    }
                }.frame(maxWidth: 660).padding(24).frame(maxWidth: .infinity, alignment: .center)
            }.modifier(MacPanelControlPresentation())
        }
    }
}
