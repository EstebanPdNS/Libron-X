import Foundation

public struct SearchWordList: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var terms: [String]
    public init(id: UUID = UUID(), name: String, terms: [String]) { self.id = id; self.name = name; self.terms = terms }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 1024, !name.contains("\0"),
              !terms.isEmpty, terms.count <= 128,
              terms.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 256 && !$0.contains("\0") }),
              Set(terms.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == terms.count
        else { throw PersonalStateError.invalid("La lista de palabras contiene datos incompatibles.") }
    }
}
public struct SearchWordLists: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var lists: [SearchWordList] = []
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard lists.count <= 1000, Set(lists.map(\.id)).count == lists.count else { throw PersonalStateError.tooLarge }
        for list in lists { try list.validate() }
    }
}
/// Each list contains alternatives. Inclusion requires at least one listed term;
/// exclusion rejects any listed term, within the normal search unit and field.
public struct SearchWordFilter: Codable, Equatable, Hashable, Sendable {
    public var include: [String]
    public var exclude: [String]
    public init(include: [String] = [], exclude: [String] = []) { self.include = include; self.exclude = exclude }
    public func compile(_ query: String) throws -> String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              include.count <= 128, exclude.count <= 128,
              (include + exclude).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 256 && !$0.contains("\0") })
        else { throw PersonalStateError.invalid("La lista de palabras contiene datos incompatibles.") }
        func expression(_ terms: [String]) -> String {
            terms.map { term in "\"" + term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: " OR ")
        }
        var result = "(" + query + ")"
        if !include.isEmpty { result += " AND (" + expression(include) + ")" }
        if !exclude.isEmpty { result += " AND NOT (" + expression(exclude) + ")" }
        _ = try SearchQueryParser.parse(result)
        return result
    }
}
