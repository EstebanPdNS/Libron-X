import Foundation

/// A user-provided passage is kept verbatim; no translation is invented.
public struct ScriptureMemoryCard: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var reference: String
    public var passage: String
    public var source: String
    public var attempts: Int
    public var correct: Int
    public var lastPracticed: ReadingDay?
    public init(id: UUID = UUID(), reference: String, passage: String, source: String = "") {
        self.id = id; self.reference = reference; self.passage = passage; self.source = source
        attempts = 0; correct = 0; lastPracticed = nil
    }
    public func validate() throws {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reference.utf8.count <= 4096, !reference.contains("\0"),
              !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              passage.utf8.count <= 64_000, !passage.contains("\0"),
              source.utf8.count <= 4096, !source.contains("\0"),
              attempts >= 0, attempts <= 1_000_000, correct >= 0, correct <= attempts,
              (attempts == 0) == (lastPracticed == nil) else {
            throw PersonalStateError.invalid("El ejercicio de memorización contiene datos incompatibles.")
        }
        if let lastPracticed { try lastPracticed.validate() }
    }
    /// Case and whitespace do not affect assessment; accents and punctuation do.
    public func matches(_ answer: String) -> Bool { Self.normalized(answer) == Self.normalized(passage) }
    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    public mutating func record(answer: String, on day: ReadingDay) throws -> Bool {
        try validate(); try day.validate()
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.utf8.count <= 64_000,
              attempts < 1_000_000, lastPracticed.map({ day >= $0 }) ?? true else {
            throw PersonalStateError.invalid("La respuesta o fecha del ejercicio no es válida.")
        }
        let result = matches(answer)
        attempts += 1; if result { correct += 1 }; lastPracticed = day
        return result
    }
}
public struct ScriptureMemory: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var cards: [ScriptureMemoryCard] = []
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard cards.count <= 10_000, Set(cards.map(\.id)).count == cards.count else { throw PersonalStateError.tooLarge }
        for card in cards { try card.validate() }
    }
}
