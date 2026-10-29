import Foundation

/// Named ranges store only user-authored reference expressions, not book text.
public struct NamedBibleSearchRange: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var expression: String
    public init(id: UUID = UUID(), name: String, expression: String) {
        self.id = id; self.name = name; self.expression = expression
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 1024, !name.contains("\0"),
              expression.utf16.count <= 16_384, !expression.contains("\0") else {
            throw PersonalStateError.invalid("El rango guardado contiene datos incompatibles.")
        }
        _ = try BibleSearchRange.parse(expression)
    }
}
public struct NamedBibleSearchRanges: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var ranges: [NamedBibleSearchRange] = []
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard ranges.count <= 1000, Set(ranges.map(\.id)).count == ranges.count else { throw PersonalStateError.tooLarge }
        for range in ranges { try range.validate() }
    }
}
