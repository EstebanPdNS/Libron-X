import Foundation

/// History is a presentation contract independent of book decoding. A failed
/// destination must not be committed. Revisiting after Back removes Forward.
public struct ReadingHistory: Sendable, Equatable, Codable {
    public private(set) var sections: [Int] = []
    public private(set) var cursor = -1
    public let limit: Int
    public init(limit: Int = 100) { self.limit = max(1, limit) }
    private enum CodingKeys: String, CodingKey { case sections, cursor, limit }
    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        let sections = try data.decode([Int].self, forKey: .sections)
        let cursor = try data.decode(Int.self, forKey: .cursor)
        let limit = try data.decode(Int.self, forKey: .limit)
        guard (1...10_000).contains(limit), sections.count <= limit, sections.allSatisfy({ $0 >= 0 }),
              sections.isEmpty ? cursor == -1 : sections.indices.contains(cursor) else {
            throw PersonalStateError.invalid("El historial guardado contiene posiciones inválidas.")
        }
        self.sections = sections; self.cursor = cursor; self.limit = limit
    }
    public var current: Int? { sections.indices.contains(cursor) ? sections[cursor] : nil }
    public var previous: Int? { cursor > 0 ? sections[cursor - 1] : nil }
    public var next: Int? { sections.indices.contains(cursor + 1) ? sections[cursor + 1] : nil }
    public mutating func visit(_ section: Int) {
        guard section >= 0, current != section else { return }
        if cursor + 1 < sections.count { sections.removeSubrange((cursor + 1)... ) }
        sections.append(section)
        if sections.count > limit { sections.removeFirst(sections.count - limit) }
        cursor = sections.count - 1
    }
    @discardableResult public mutating func back() -> Int? {
        guard previous != nil else { return nil }; cursor -= 1; return current
    }
    @discardableResult public mutating func forward() -> Int? {
        guard next != nil else { return nil }; cursor += 1; return current
    }
}
