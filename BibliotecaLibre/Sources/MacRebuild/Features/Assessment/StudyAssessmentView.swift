import SwiftUI
import LibronixCore

private struct AssessmentEdit: Identifiable { let id = UUID(); let original: StudyAssessment? }
struct StudyAssessmentView: View {
    @Bindable var personal: WorkspacePersonalState
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var editing: AssessmentEdit?
    @RebuildViewState private var practicing: StudyAssessment?
    @RebuildViewState private var deleting = false
    @RebuildViewState private var error: String?
    private var selected: StudyAssessment? { personal.studyAssessments.assessments.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(personal.studyAssessments.assessments, selection: $selectedID) { assessment in
                VStack(alignment: .leading, spacing: 4) {
                    Text(assessment.title).font(.headline)
                    if let result = assessment.results.last {
                        Text(LF("Resultado: {correct} de {total}", ["correct": String(result.correct), "total": String(result.total)]))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.tag(assessment.id)
            }.overlay { if personal.studyAssessments.assessments.isEmpty { Text(L("No hay autoevaluaciones.")).foregroundStyle(.secondary).allowsHitTesting(false) } }
            if let message = error ?? personal.studyAssessmentsLoadError { Text(L(message)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            MacReaderToolbarSurface {
                HStack {
                    MacReaderControlGroup {
                        MacToolbarButton("Añadir autoevaluación", "plus") { editing = .init(original: nil) }
                        MacToolbarButton("Editar autoevaluación", "pencil") { if let selected { editing = .init(original: selected) } }.disabled(selected == nil)
                        MacToolbarButton("Eliminar autoevaluación", "trash") { deleting = true }.disabled(selected == nil)
                    }
                    Spacer(); Button(L("Practicar")) { practicing = selected }.disabled(selected?.questions.isEmpty != false)
                }
            }
        }.padding(16)
            .sheet(item: $editing) { draft in AssessmentEditor(personal: personal, original: draft.original) { selectedID = $0 }.modifier(AppInterfaceLanguage()) }
            .sheet(item: $practicing) { assessment in AssessmentPractice(personal: personal, original: assessment).modifier(AppInterfaceLanguage()) }
            .alert(L("Eliminar autoevaluación"), isPresented: $deleting) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Eliminar"), role: .destructive) { remove() }
            } message: { Text(L("Se eliminará la autoevaluación y sus resultados.")) }
    }
    private func remove() {
        guard let selected else { return }
        do {
            try personal.editStudyAssessments { state in
                guard let index = state.assessments.firstIndex(of: selected) else { throw PersonalStateError.concurrentChange }
                state.assessments.remove(at: index)
            }
            selectedID = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
private struct AssessmentEditor: View {
    @Bindable var personal: WorkspacePersonalState
    let original: StudyAssessment?
    let saved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var title = ""
    @RebuildViewState private var questions: [StudyQuestion] = []
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var addedSelectionID: UUID?
    @RebuildViewState private var prompt = ""
    @RebuildViewState private var expected = ""
    @RebuildViewState private var error: String?
    private var selected: StudyQuestion? { questions.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: original == nil ? "Añadir autoevaluación" : "Editar autoevaluación") { dismiss() }
            MacBoundTextField(title: L("Título"), text: $title).macInputStyle()
            List(questions, selection: $selectedID) { question in MacSourceText(text: question.prompt).lineLimit(2).tag(question.id) }
                .frame(height: min(240, max(96, CGFloat(questions.count) * 36)))
                .overlay { if questions.isEmpty { Text(L("No hay preguntas.")).foregroundStyle(.secondary).allowsHitTesting(false) } }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Pregunta")).font(.caption).foregroundStyle(.secondary)
                MacBoundTextField(title: L("Pregunta"), text: $prompt).macInputStyle()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Respuesta esperada")).font(.caption).foregroundStyle(.secondary)
                MacBoundTextField(title: L("Respuesta esperada"), text: $expected).macInputStyle()
            }
            HStack {
                Button(L("Añadir pregunta")) { changeQuestion(add: true) }
                Button(L("Actualizar pregunta")) { changeQuestion(add: false) }.disabled(selected == nil)
                Button(L("Eliminar pregunta")) { if let selected { questions.removeAll { $0.id == selected.id }; selectedID = nil } }.disabled(selected == nil)
                Spacer()
            }
            if original != nil { Text(L("Cambiar las preguntas reinicia los resultados anteriores.")).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button(L("Cancelar")) { dismiss() }; Button(L("Guardar"), action: save) }
        }.padding(16).frame(width: 650).modifier(MacPanelControlPresentation())
            .onAppear { if let original { title = original.title; questions = original.questions } }
            .onChange(of: selectedID) {
                if selectedID != nil && selectedID == addedSelectionID { addedSelectionID = nil; return }
                addedSelectionID = nil; prompt = selected?.prompt ?? ""; expected = selected?.expectedAnswer ?? ""
            }
    }
    private func changeQuestion(add: Bool) {
        do {
            var question = add ? StudyQuestion(prompt: prompt, expectedAnswer: expected) : (selected ?? StudyQuestion(prompt: prompt, expectedAnswer: expected))
            if !add && selected == nil { return }
            question.prompt = prompt; question.expectedAnswer = expected; try question.validate()
            if add { questions.append(question); addedSelectionID = question.id }
            else if let index = questions.firstIndex(where: { $0.id == question.id }) { questions[index] = question }
            selectedID = question.id; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            var draftQuestions = questions
            if let selected, let index = draftQuestions.firstIndex(where: { $0.id == selected.id }) {
                var draft = selected; draft.prompt = prompt; draft.expectedAnswer = expected; try draft.validate()
                draftQuestions[index] = draft
            } else if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let draft = StudyQuestion(prompt: prompt, expectedAnswer: expected); try draft.validate(); draftQuestions.append(draft)
            }
            var value = original ?? StudyAssessment(title: title)
            value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if original?.questions != draftQuestions { value.results = [] }
            value.questions = draftQuestions; try value.validate()
            try personal.editStudyAssessments { state in
                if let original {
                    guard let index = state.assessments.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                    state.assessments[index] = value
                } else { state.assessments.append(value) }
            }
            saved(value.id); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
private struct AssessmentPractice: View {
    @Bindable var personal: WorkspacePersonalState
    let original: StudyAssessment
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var answers: [UUID: String] = [:]
    @RebuildViewState private var result: StudyAssessmentResult?
    @RebuildViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Practicar") { dismiss() }
            Text(original.title).font(.headline)
            Text(L("Se ignoran mayúsculas y espacios; los acentos y la puntuación cuentan.")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(original.questions) { question in
                        VStack(alignment: .leading, spacing: 6) {
                            MacSourceText(text: question.prompt)
                            MacBoundTextField(title: L("Respuesta"), text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 })).macInputStyle().disabled(result != nil)
                            if result != nil {
                                Text(L(question.matches(answers[question.id] ?? "") ? "Respuesta correcta" : "Respuesta diferente"))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(L("Respuesta esperada")).font(.caption).foregroundStyle(.secondary)
                                MacSourceText(text: question.expectedAnswer).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let result { Text(LF("Resultado: {correct} de {total}", ["correct": String(result.correct), "total": String(result.total)])).font(.headline) }
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button(L("Cerrar")) { dismiss() }; Button(L("Calificar"), action: grade).disabled(result != nil) }
        }.padding(16).frame(width: 650, height: 550).modifier(MacPanelControlPresentation())
    }
    private func grade() {
        do {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
            let parts = calendar.dateComponents([.year, .month, .day], from: Date())
            guard let year = parts.year, let month = parts.month, let day = parts.day else { throw PersonalStateError.invalid("La respuesta o fecha del ejercicio no es válida.") }
            var updated = original
            let outcome = try updated.submit(answers: answers, on: ReadingDay(year: year, month: month, day: day))
            try personal.editStudyAssessments { state in
                guard let index = state.assessments.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                state.assessments[index] = updated
            }
            result = outcome; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
