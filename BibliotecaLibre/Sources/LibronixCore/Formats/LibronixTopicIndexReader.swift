import Foundation

public struct LibronixIndexedTopic: Sendable, Equatable {
    public let text: String
    /// Original index referents. These are not assumed to be physical articles.
    public let referents: [UInt32]
}
public struct LibronixNamedTopicIndex: Sendable, Equatable {
    public let name: String
    public let stringEncoding: UInt32
    public let topics: [LibronixIndexedTopic]
    /// Original display labels may differ in accents/case from lookup keys.
    public let labelsByReferent: [UInt32: [String]]
}
public enum LibronixTopicIndexFailure: Error, LocalizedError, Sendable, Equatable {
    case unsupportedProfile, malformed, limitExceeded, missingTopics
    public var errorDescription: String? {
        switch self {
        case .unsupportedProfile: "Esta versión o codificación del índice temático todavía no tiene un lector comprobado."
        case .malformed: "El índice temático contiene rangos, árboles o asociaciones inválidos."
        case .limitExceeded: "El índice temático supera el presupuesto de lectura."
        case .missingTopics: "El índice de búsqueda no contiene un árbol temático con el nombre esperado."
        }
    }
}

/// Reads the IX/TO 1/2/3 named-topic trees in fullindex.dat. This does not
/// substitute title matching or assume that a referent equals a section ordinal.
public enum LibronixTopicIndexReader {
    private static let maximumValues = 4_000_000
    private static let maximumTextUnits = 16_000_000
    private static let maximumEntries = 512_000
    public static func read(_ input: Data) throws -> [LibronixNamedTopicIndex] {
        try Task.checkCancellation()
        guard input.count <= 32 * 1024 * 1024 else { throw LibronixTopicIndexFailure.limitExceeded }
        let data: Data
        if input.starts(with: Data("LZCS".utf8)) {
            var envelope = TopicIndexCursor(Array(input), at: 12)
            let logicalLow = try envelope.u32(), logicalHigh = try envelope.u32()
            guard logicalHigh == 0, logicalLow <= 64 * 1024 * 1024 else { throw LibronixTopicIndexFailure.limitExceeded }
            data = try LTESContainerReader.decodeLZCS(input).0
        } else { data = input }
        guard data.count <= 64 * 1024 * 1024 else { throw LibronixTopicIndexFailure.limitExceeded }
        let bytes = Array(data)
        var c = TopicIndexCursor(bytes)
        guard try c.u16() == 0x5849 else { throw LibronixTopicIndexFailure.unsupportedProfile }
        let version = try c.u16()
        guard [1, 2, 3].contains(version) else { throw LibronixTopicIndexFailure.unsupportedProfile }
        guard try c.u32() == data.count else { throw LibronixTopicIndexFailure.malformed }
        let count = Int(try c.u16()); _ = try c.u16(); _ = try c.u16()
        if version == 3, try c.u32() != 0 { throw LibronixTopicIndexFailure.unsupportedProfile }
        guard count <= 1024 else { throw LibronixTopicIndexFailure.limitExceeded }
        var members: [(String, Int)] = []
        for _ in 0..<count {
            let nameBytes = try c.take(10)
            guard let nul = nameBytes.firstIndex(of: 0), nul > nameBytes.startIndex,
                  let name = String(bytes: nameBytes[..<nul], encoding: .ascii) else { throw LibronixTopicIndexFailure.malformed }
            members.append((name, Int(try c.u32())))
        }
        guard Set(members.map(\.0)).count == members.count,
              Set(members.map(\.1)).count == members.count,
              members.allSatisfy({ $0.1 >= c.at && $0.1 <= data.count - 8 }) else { throw LibronixTopicIndexFailure.malformed }
        guard let member = members.first(where: { $0.0 == "topics" }) else { throw LibronixTopicIndexFailure.missingTopics }
        c.at = member.1
        guard try c.u16() == 0x4f54, [1, 2, 3].contains(try c.u16()) else { throw LibronixTopicIndexFailure.unsupportedProfile }
        let length = Int(try c.u32())
        guard length >= 33, length <= data.count - member.1,
              !members.contains(where: { $0.1 > member.1 && $0.1 < member.1 + length }) else { throw LibronixTopicIndexFailure.malformed }
        c.at = member.1 + 27
        let namedCount = Int(try c.u16()), directory = Int(try c.u32()), end = member.1 + length
        guard namedCount <= 1024 else { throw LibronixTopicIndexFailure.limitExceeded }
        guard directory >= 33, directory <= length else { throw LibronixTopicIndexFailure.malformed }
        c.at = member.1 + directory; c.end = end
        var entries: [(name: String, encoding: UInt32, words: Int, refs: Int)] = []
        for _ in 0..<namedCount {
            let name = try c.string(encoding: 0), flags = try c.variable()
            let words = Int(try c.u32()), refs = Int(try c.u32())
            guard flags & ~UInt32(14) == 0, [0, 2, 4].contains(flags & 14) else { throw LibronixTopicIndexFailure.unsupportedProfile }
            guard !name.isEmpty, words >= 33, words + 6 <= refs, refs + 6 <= directory else { throw LibronixTopicIndexFailure.malformed }
            entries.append((name, flags & 14, words, refs))
        }
        guard c.at == end, Set(entries.map { Array($0.name.utf16) }).count == entries.count else { throw LibronixTopicIndexFailure.malformed }
        let ordered = entries.sorted { $0.words < $1.words }
        var output: [LibronixNamedTopicIndex] = [], totalValues = 0, totalText = 0
        for (index, entry) in ordered.enumerated() {
            let upper = index + 1 < ordered.count ? ordered[index + 1].words : directory
            guard entry.refs + 6 <= upper else { throw LibronixTopicIndexFailure.malformed }
            var forward: [LibronixIndexedTopic] = [], reverse: [UInt32: [String]] = [:]
            func readTree(base: Int, upper: Int, reversed: Bool) throws {
                var cursor = TopicIndexCursor(bytes, at: base, end: upper)
                let root = Int(try cursor.u32())
                var visited = Set<Int>(), ranges: [Range<Int>] = []
                func visit(_ offset: Int, depth: Int) throws {
                    try Task.checkCancellation()
                    guard depth <= 32, visited.count < 100_000 else { throw LibronixTopicIndexFailure.limitExceeded }
                    guard offset >= 4, offset < upper - base, visited.insert(offset).inserted else { throw LibronixTopicIndexFailure.malformed }
                    var node = TopicIndexCursor(bytes, at: base + offset, end: upper)
                    let count = Int(try node.byte()), leaf = try node.byte()
                    guard leaf <= 1 else { throw LibronixTopicIndexFailure.malformed }
                    var children: [Int] = []
                    if leaf == 0 { for _ in 0...count { children.append(Int(try node.u32())) } }
                    var items: [(String?, UInt32?, [UInt32], [String])] = []
                    for _ in 0..<count {
                        let text: String? = reversed ? nil : try node.string(encoding: entry.encoding)
                        let key: UInt32? = reversed ? try node.variable() : nil
                        let values = Int(try node.variable())
                        guard values <= maximumValues - totalValues else { throw LibronixTopicIndexFailure.limitExceeded }
                        totalValues += values
                        var ids: [UInt32] = [], labels: [String] = []
                        totalText += text?.utf16.count ?? 0
                        for _ in 0..<values {
                            if reversed {
                                let label = try node.string(encoding: entry.encoding)
                                totalText += label.utf16.count
                                guard totalText <= maximumTextUnits else { throw LibronixTopicIndexFailure.limitExceeded }
                                labels.append(label)
                            } else { ids.append(try node.variable()) }
                        }
                        guard totalText <= maximumTextUnits else { throw LibronixTopicIndexFailure.limitExceeded }
                        items.append((text, key, ids, labels))
                    }
                    ranges.append((base + offset)..<node.at)
                    for (index, item) in items.enumerated() {
                        if !children.isEmpty { try visit(children[index], depth: depth + 1) }
                        if let key = item.1 {
                            guard reverse.updateValue(item.3, forKey: key) == nil else { throw LibronixTopicIndexFailure.malformed }
                        } else { forward.append(.init(text: item.0!, referents: item.2)) }
                        guard forward.count + reverse.count <= maximumEntries else { throw LibronixTopicIndexFailure.limitExceeded }
                    }
                    if !children.isEmpty { try visit(children[count], depth: depth + 1) }
                }
                try visit(root, depth: 0)
                ranges.sort { $0.lowerBound < $1.lowerBound }
                guard zip(ranges, ranges.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound }) else { throw LibronixTopicIndexFailure.malformed }
            }
            try readTree(base: member.1 + entry.words, upper: member.1 + entry.refs, reversed: false)
            try readTree(base: member.1 + entry.refs, upper: member.1 + upper, reversed: true)
            guard Set(forward.map { Array($0.text.utf16) }).count == forward.count,
                  forward.allSatisfy({ $0.referents.allSatisfy { reverse[$0] != nil } }) else { throw LibronixTopicIndexFailure.malformed }
            output.append(.init(name: entry.name, stringEncoding: entry.encoding, topics: forward, labelsByReferent: reverse))
        }
        return output
    }
}

private struct TopicIndexCursor {
    let bytes: [UInt8]
    var at: Int
    var end: Int
    init(_ bytes: [UInt8], at: Int = 0, end: Int? = nil) { self.bytes = bytes; self.at = at; self.end = end ?? bytes.count }
    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, at >= 0, at <= end, end <= bytes.count, count <= end - at else { throw LibronixTopicIndexFailure.malformed }
        defer { at += count }; return bytes[at..<(at + count)]
    }
    mutating func byte() throws -> UInt8 { try take(1).first! }
    mutating func u16() throws -> UInt16 { let b = try take(2); return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8 }
    mutating func u32() throws -> UInt32 { let b = try take(4); return b.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) } }
    mutating func variable() throws -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, through: 28, by: 7) {
            let b = try byte()
            guard shift != 28 || b <= 15 else { throw LibronixTopicIndexFailure.malformed }
            value |= UInt32(b & 127) << shift
            if b < 128 { return value }
        }
        throw LibronixTopicIndexFailure.malformed
    }
    mutating func string(encoding: UInt32) throws -> String {
        let length = Int(try variable())
        guard length <= 65_536 else { throw LibronixTopicIndexFailure.limitExceeded }
        let data = Data(try take(length * (encoding == 0 ? 2 : 1)))
        if encoding == 4 { return try SCSUDecoder.decode(data) }
        guard let result = String(data: data, encoding: encoding == 0 ? .utf16LittleEndian : .utf8) else { throw LibronixTopicIndexFailure.malformed }
        return result
    }
}
