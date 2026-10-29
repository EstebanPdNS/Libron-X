import SwiftUI
import LibronixCore

struct WorkspaceSearchOptionsView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var search: WorkspaceSearchController
    @Binding var namedRangesOpen: Bool
    let run: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("Opciones de búsqueda"), systemImage: "slider.horizontal.3").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                WorkspaceSearchScopePicker(selection: search.scope, context: workspace.searchScopeContext(), stacked: true)
                Divider()
                WorkspaceSearchFieldPicker(field: $search.searchField)
                WorkspaceSearchMatchingPicker(search: search)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(L("Mayúsculas"), isOn: $search.caseSensitive)
                    Toggle(L("Palabras completas"), isOn: $search.wholeWords)
                    Toggle(L("Versículos bíblicos"), isOn: $search.bibleVerses)
                }
            if search.bibleVerses {
                VStack(alignment: .leading, spacing: 8) {
                    MacSelectionMenu(L("Rango bíblico"), value: rangeTitle(search.bibleRangeMode), selection: $search.bibleRangeMode, fillsWidth: true) {
                        Text(L("Todos los versículos")).tag(WorkspaceBibleRangeMode.all)
                        Text(L("Pasajes o libros")).tag(WorkspaceBibleRangeMode.custom)
                        Text(L("Lista guardada")).tag(WorkspaceBibleRangeMode.savedList)
                        Text(L("Rango guardado")).tag(WorkspaceBibleRangeMode.namedRange)
                    }
                    if search.bibleRangeMode == .custom {
                        TextField(L("Pasajes, por ejemplo Gn 1–3; Juan 3:16–18; Romanos"), text: $search.customBibleRange)
                            .macInputStyle().onSubmit(run)
                    } else if search.bibleRangeMode == .savedList {
                        MacSelectionMenu(L("Lista de versículos"), value: workspace.personal.documents.first { $0.id == search.referenceListID }?.title ?? L("Selecciona una lista de versículos"), selection: $search.referenceListID, fillsWidth: true) {
                            Text(L("Selecciona una lista de versículos")).tag(Optional<UUID>.none)
                            ForEach(workspace.personal.documents.filter { $0.kind == .verseList }) {
                                Text($0.title).tag(Optional($0.id))
                            }
                        }
                    } else if search.bibleRangeMode == .namedRange {
                        MacSelectionMenu(L("Rango guardado"), value: workspace.personal.namedBibleRanges.ranges.first { $0.id == search.namedRangeID }?.name ?? L("Selecciona un rango guardado"), selection: $search.namedRangeID, fillsWidth: true) {
                            Text(L("Selecciona un rango guardado")).tag(Optional<UUID>.none)
                            ForEach(workspace.personal.namedBibleRanges.ranges) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    MacSelectionMenu(L("Excluir referencias"), value: search.excludedRange.mode == .all ? L("Sin exclusiones") : rangeTitle(search.excludedRange.mode), selection: $search.excludedRange.mode, fillsWidth: true) {
                        Text(L("Sin exclusiones")).tag(WorkspaceBibleRangeMode.all)
                        Text(L("Pasajes o libros")).tag(WorkspaceBibleRangeMode.custom)
                        Text(L("Lista guardada")).tag(WorkspaceBibleRangeMode.savedList)
                        Text(L("Rango guardado")).tag(WorkspaceBibleRangeMode.namedRange)
                    }
                    if search.excludedRange.mode == .custom {
                        TextField(L("Pasajes, por ejemplo Gn 1–3; Juan 3:16–18; Romanos"), text: $search.excludedRange.customRange)
                            .macInputStyle().onSubmit(run)
                    } else if search.excludedRange.mode == .savedList {
                        MacSelectionMenu(L("Lista de versículos excluidos"), value: workspace.personal.documents.first { $0.id == search.excludedRange.referenceListID }?.title ?? L("Selecciona una lista de versículos"), selection: $search.excludedRange.referenceListID, fillsWidth: true) {
                            Text(L("Selecciona una lista de versículos")).tag(Optional<UUID>.none)
                            ForEach(workspace.personal.documents.filter { $0.kind == .verseList }) {
                                Text($0.title).tag(Optional($0.id))
                            }
                        }
                    } else if search.excludedRange.mode == .namedRange {
                        MacSelectionMenu(L("Rango excluido"), value: workspace.personal.namedBibleRanges.ranges.first { $0.id == search.excludedRange.namedRangeID }?.name ?? L("Selecciona un rango guardado"), selection: $search.excludedRange.namedRangeID, fillsWidth: true) {
                            Text(L("Selecciona un rango guardado")).tag(Optional<UUID>.none)
                            ForEach(workspace.personal.namedBibleRanges.ranges) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    Button(L("Gestionar rangos…")) { namedRangesOpen = true }
                }.disabled(search.isSearching)
            }

                Divider()
                WorkspaceWordFiltersView(search: search, personal: workspace.personal)
                WorkspaceSearchLimitsView(search: search)
            if !search.approximatePhrase {
            DisclosureGroup(L("Operadores de búsqueda")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "title:a · body:(a AND b) · footnote:a\nheading:a · bible:a · quote:a")
                    Text(verbatim: "a NEAR b · a NEAR/2 b · a BEFORE b · a AFTER b\na WITHIN 2 WORDS b · a BEFORE 2 CHARACTERS b\na WITHIN 1 VERSES b · (a OR b) BEFORE/0 c")
                    Text(L("NEAR usa 48 unidades UTF-16. WORDS cuenta palabras intermedias. VERSES usa referencias reales del mismo capítulo. Cada artículo o versículo conserva su ámbito."))
                }.font(.caption).textSelection(.enabled)
            }
            }

            }.disabled(search.isSearching).padding(.horizontal, 4).padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.visible).accessibilityLabel(L("Opciones de búsqueda"))
        }
    }
    private func rangeTitle(_ mode: WorkspaceBibleRangeMode) -> String {
        switch mode {
        case .all: L("Todos los versículos")
        case .custom: L("Pasajes o libros")
        case .savedList: L("Lista guardada")
        case .namedRange: L("Rango guardado")
        }
    }
}
