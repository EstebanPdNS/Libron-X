import SwiftUI
import LibronixCore

struct WorkspaceSearchLimitsView: View {
    @Bindable var search: WorkspaceSearchController
    var body: some View {
        DisclosureGroup(L("Límites de búsqueda")) {
            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                        Text(L("Duración activa (s)"))
                        TextField(L("Duración activa (s)"), value: $search.limits.durationSeconds, format: .number).macInputStyle()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                        Text(L("Artículos máximos"))
                        TextField(L("Artículos máximos"), value: $search.limits.articles, format: .number).macInputStyle()
                        }
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                        Text(L("Resultados máximos"))
                        TextField(L("Resultados máximos"), value: $search.limits.results, format: .number).macInputStyle()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                        Text(L("Coincidencias máximas"))
                        TextField(L("Coincidencias máximas"), value: $search.limits.occurrences, format: .number).macInputStyle()
                        }
                    }
                }.font(.caption).disabled(search.isSearching)
                Text(L("Hasta 3600 s, 500000 artículos, 10000 resultados y 1000000 coincidencias."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("Los cambios se aplican a la próxima búsqueda. Alcanzar un límite termina la búsqueda con cobertura parcial."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct WorkspaceSearchRunStatusView: View {
    @Bindable var search: WorkspaceSearchController
    var body: some View {
        if search.phase != .idle {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if [.running,.pausing,.cancelling].contains(search.phase) { ProgressView().controlSize(.small) }
                    Text(status).font(.caption)
                }
                if let progress = search.progress {
                    Text(LF("{count} artículos examinados · {seconds} s de trabajo activo", [
                        "count": String(search.report?.counters.articlesExamined ?? progress.counters.articlesExamined),
                        "seconds": (search.report?.elapsedSeconds ?? progress.elapsedSeconds).formatted(.number.precision(.fractionLength(1)))
                    ])).font(.caption).foregroundStyle(.secondary)
                }
                if search.isSearching {
                    Text(L("Pausar espera a que termine el artículo o versículo actual. Al cerrar esta ventana, la búsqueda se pausa."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var status: String {
        switch search.phase {
        case .idle: ""
        case .running: L("Buscando…")
        case .pausing: L("Esperando el punto de pausa…")
        case .paused: L("Búsqueda pausada")
        case .cancelling: L("Cancelando búsqueda…")
        case .cancelled: L("Búsqueda cancelada; se conservan los resultados parciales.")
        case .finished: search.report?.coverageComplete == true ? L("Búsqueda terminada") : L("Búsqueda terminada con cobertura parcial")
        case .failed: L("La búsqueda falló. Inicia una búsqueda nueva para abrir resultados.")
        }
    }
}

extension LibrarySearchLimit {
    @MainActor var localizedTitle: String {
        switch self {
        case .duration: L("Duración activa (s)")
        case .articles: L("Artículos máximos")
        case .results: L("Resultados máximos")
        case .occurrences: L("Coincidencias máximas")
        }
    }
}
