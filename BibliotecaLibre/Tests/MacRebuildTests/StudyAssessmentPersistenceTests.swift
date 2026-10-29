import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct StudyAssessmentPersistenceTests {
    @Test func scoresPersistAndConcurrentWritesFail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json"), first = WorkspacePersonalState(url: url), stale = WorkspacePersonalState(url: url)
        let question = StudyQuestion(prompt: "Question?", expectedAnswer: "Answer")
        let quiz = StudyAssessment(title: "Study", questions: [question])
        try first.editStudyAssessments { $0.assessments.append(quiz) }
        #expect(throws: (any Error).self) { try stale.editStudyAssessments { $0.assessments.append(quiz) } }
        try first.editStudyAssessments { _ = try $0.assessments[0].submit(answers: [question.id: "answer"], on: ReadingDay(year: 2026, month: 10, day: 28)) }
        let reloaded = WorkspacePersonalState(url: url)
        #expect(reloaded.studyAssessments.assessments.first?.results.first?.correct == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func futureFilesRemainUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("study-assessments.json"), bytes = Data(#"{"schemaVersion":99,"assessments":[]}"#.utf8)
        try bytes.write(to: path)
        let state = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        #expect(state.studyAssessmentsLoadError != nil)
        #expect(throws: (any Error).self) { try state.editStudyAssessments { $0.assessments = [] } }
        #expect(try Data(contentsOf: path) == bytes)
    }
}
