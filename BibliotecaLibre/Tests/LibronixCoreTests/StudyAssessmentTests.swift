import Foundation
import Testing
@testable import LibronixCore

struct StudyAssessmentTests {
    @Test func scoresOnlyCompleteAnswersAndPreservesResults() throws {
        let first = StudyQuestion(prompt: "One?", expectedAnswer: "Alpha"), second = StudyQuestion(prompt: "Two?", expectedAnswer: "Béta.")
        var quiz = StudyAssessment(title: "Study", questions: [first, second])
        let date = try ReadingDay(year: 2026, month: 10, day: 28)
        #expect(throws: (any Error).self) { try quiz.submit(answers: [first.id: "alpha"], on: date) }
        #expect(quiz.results.isEmpty)
        let result = try quiz.submit(answers: [first.id: " ALPHA ", second.id: "beta."], on: date)
        #expect(result.correct == 1 && result.total == 2 && quiz.results == [result])
        var state = StudyAssessments(); state.assessments = [quiz]; try state.validate()
        #expect(try JSONDecoder().decode(StudyAssessments.self, from: JSONEncoder().encode(state)) == state)
    }
    @Test func rejectsDuplicateQuestionIDsAndInvalidScores() throws {
        let question = StudyQuestion(prompt: "One?", expectedAnswer: "Yes")
        var quiz = StudyAssessment(title: "Study", questions: [question, question])
        #expect(throws: (any Error).self) { try quiz.validate() }
        quiz.questions.removeLast(); quiz.results = [.init(date: try ReadingDay(year: 2026, month: 10, day: 28), correct: 2, total: 1)]
        #expect(throws: (any Error).self) { try quiz.validate() }
    }
}
