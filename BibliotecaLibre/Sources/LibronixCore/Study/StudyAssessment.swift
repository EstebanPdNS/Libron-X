import Foundation

public struct StudyQuestion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var prompt: String
    public var expectedAnswer: String
    public init(id: UUID = UUID(), prompt: String, expectedAnswer: String) {
        self.id = id; self.prompt = prompt; self.expectedAnswer = expectedAnswer
    }
    public func validate() throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !expectedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 16_000, expectedAnswer.utf8.count <= 16_000,
              !prompt.contains("\0"), !expectedAnswer.contains("\0") else {
            throw PersonalStateError.invalid("La pregunta o respuesta esperada no es válida.")
        }
    }
    public func matches(_ answer: String) -> Bool { Self.normalized(answer) == Self.normalized(expectedAnswer) }
    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
public struct StudyAssessmentResult: Codable, Equatable, Sendable {
    public var date: ReadingDay
    public var correct: Int
    public var total: Int
    public init(date: ReadingDay, correct: Int, total: Int) { self.date = date; self.correct = correct; self.total = total }
}
public struct StudyAssessment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var questions: [StudyQuestion]
    public var results: [StudyAssessmentResult]
    public init(id: UUID = UUID(), title: String, questions: [StudyQuestion] = []) {
        self.id = id; self.title = title; self.questions = questions; results = []
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 4096,
              !title.contains("\0"), questions.count <= 100, Set(questions.map(\.id)).count == questions.count,
              results.count <= 10_000 else { throw PersonalStateError.invalid("La autoevaluación contiene datos incompatibles.") }
        for question in questions { try question.validate() }
        for result in results {
            try result.date.validate()
            guard result.total > 0, result.total <= 100, result.correct >= 0, result.correct <= result.total
            else { throw PersonalStateError.invalid("La autoevaluación contiene datos incompatibles.") }
        }
    }
    /// Requires exactly one nonempty response per question; no answers are stored.
    public mutating func submit(answers: [UUID: String], on date: ReadingDay) throws -> StudyAssessmentResult {
        try validate(); try date.validate()
        guard !questions.isEmpty, results.count < 10_000, answers.count == questions.count,
              questions.allSatisfy({ question in
                  guard let answer = answers[question.id] else { return false }
                  return !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && answer.utf8.count <= 16_000
              }) else { throw PersonalStateError.invalid("Responde todas las preguntas antes de calificar.") }
        let result = StudyAssessmentResult(date: date, correct: questions.filter { $0.matches(answers[$0.id]!) }.count, total: questions.count)
        results.append(result); return result
    }
}
public struct StudyAssessments: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var assessments: [StudyAssessment] = []
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard assessments.count <= 1000, Set(assessments.map(\.id)).count == assessments.count else { throw PersonalStateError.tooLarge }
        for assessment in assessments { try assessment.validate() }
    }
}
