import Foundation

/// Explicit compatibility dialects. The existing SearchQueryParser remains a
/// separate strict grammar; this parser does not execute searches or scripts.
public enum LegacyQueryDialect: String, Codable, CaseIterable, Sendable {
    case basic = "QueryParser"
    case advanced = "AdvancedQueryParser"
}

public struct LegacyQueryLimits: Sendable, Equatable {
    public var maximumSourceUTF16: Int
    public var maximumTokens: Int
    public var maximumOperandUTF16: Int
    public var maximumNodes: Int
    public var maximumNesting: Int
    public var maximumASTDepth: Int
    public init(maximumSourceUTF16: Int = 16_384, maximumTokens: Int = 512,
                maximumOperandUTF16: Int = 4_096, maximumNodes: Int = 1_024,
                maximumNesting: Int = 32, maximumASTDepth: Int = 128) {
        self.maximumSourceUTF16 = maximumSourceUTF16; self.maximumTokens = maximumTokens
        self.maximumOperandUTF16 = maximumOperandUTF16; self.maximumNodes = maximumNodes
        self.maximumNesting = maximumNesting; self.maximumASTDepth = maximumASTDepth
    }
}

public struct LegacyQueryError: Error, Equatable, LocalizedError, Sendable {
    public enum Code: String, Codable, Sendable {
        case invalidLimits, sourceLimit, tokenLimit, operandLimit, nodeLimit, nestingLimit, astDepthLimit
        case emptyQuery, unterminatedQuote, expectedTerm, missingOperand, missingClose, unexpectedToken
        case fieldsUnavailable, withinUnavailable, unsupportedProximityParameters, advancedQueryRequired
    }
    public let code: Code
    public let range: SearchTextRange
    public var errorDescription: String? { "Legacy query reference: \(code.rawValue) at UTF-16 offset \(range.location)." }
    init(_ code: Code, _ range: SearchTextRange) { self.code = code; self.range = range }
}

public struct LegacyQueryOperand: Equatable, Sendable {
    public let text: String
    public let sourceRange: SearchTextRange
    public let quoted: Bool
    public let field: String?
}
public enum LegacyQueryDistanceUnit: String, Codable, Sendable { case words = "WORDS", characters = "CHARS" }
public enum LegacyQueryBinaryKind: String, Codable, Sendable {
    case conjunction = "and", disjunction = "or", andNot = "and-not", near, before, within
}
public struct LegacyQueryOperator: Equatable, Sendable {
    public let kind: LegacyQueryBinaryKind
    public let sourceRange: SearchTextRange
    public let maximumDistance: Int?
    public let distanceUnit: LegacyQueryDistanceUnit?
}
public indirect enum LegacyQueryExpression: Equatable, Sendable {
    case term(LegacyQueryOperand)
    case natural([LegacyQueryExpression])
    case binary(LegacyQueryOperator, LegacyQueryExpression, LegacyQueryExpression)
    case negation(SearchTextRange, LegacyQueryExpression)
}

/// Normalized interchange tree. It preserves child order and exact term text.
/// This representation is not an evaluator and never executes its contents.
public struct LegacyQueryTree: Codable, Equatable, Sendable {
    public let tag: String
    public let attributes: [String: String]
    public let text: String
    public let children: [LegacyQueryTree]
    init(_ tag: String, _ attributes: [String: String] = [:], _ text: String = "", _ children: [LegacyQueryTree] = []) {
        self.tag = tag; self.attributes = attributes; self.text = text; self.children = children
    }
}
public struct LegacyParsedQuery: Equatable, Sendable {
    public let source: String
    public let dialect: LegacyQueryDialect
    public let expression: LegacyQueryExpression
    public var tree: LegacyQueryTree {
        .init("query", dialect == .basic ? ["type": "lbx-xml"] : [:], "", [expression.tree(dialect)])
    }
}

private extension LegacyQueryExpression {
    var depth: Int {
        switch self {
        case .term: return 1
        case .natural(let values): return 1 + (values.map(\.depth).max() ?? 0)
        case .binary(_, let left, let right): return 1 + max(left.depth, right.depth)
        case .negation(_, let value): return 1 + value.depth
        }
    }
    func tree(_ dialect: LegacyQueryDialect) -> LegacyQueryTree {
        func span(_ range: SearchTextRange) -> [String: String] {
            dialect == .advanced ? ["offset": String(range.location), "length": String(range.length)] : [:]
        }
        switch self {
        case .term(let value):
            var attributes = span(value.sourceRange)
            if let field = value.field { attributes["fields"] = "1"; attributes["field1"] = field }
            return .init("term", attributes, value.text)
        case .natural(let values): return .init("natural", [:], "", values.map { $0.tree(dialect) })
        case .negation(let range, let value): return .init("not", span(range), "", [value.tree(dialect)])
        case .binary(let op, let left, let right):
            var attributes = span(op.sourceRange)
            if let distance = op.maximumDistance { attributes["max"] = String(distance) }
            if let unit = op.distanceUnit { attributes["unit"] = unit.rawValue }
            return .init(op.kind.rawValue, attributes, "", [left.tree(dialect), right.tree(dialect)])
        }
    }
}

public struct LegacyEngineTerm: Equatable, Sendable { public let id: String; public let text: String }
public indirect enum LegacyEngineExpression: Equatable, Sendable {
    case term(LegacyEngineTerm), any
    case conjunction([LegacyEngineExpression]), disjunction([LegacyEngineExpression])
    case andNot(LegacyEngineExpression, LegacyEngineExpression)
}
public struct LegacyEngineAlias: Equatable, Sendable { public let name: String; public let field: String }
public struct LegacyEngineDistance: Equatable, Sendable {
    public enum Unit: String, Codable, Sendable { case word, character }
    public let termIDs: [String]
    public let maximum: Int?
    /// nil preserves an omitted XML attribute. The verified modern constructor
    /// selects its character enum; physical hit-coordinate units remain separate.
    public let unit: Unit?
    public let before: Bool
    /// Projects verified modern constructor defaults without evaluating hits or
    /// changing the serialized query. Signed numeric overflow behavior is outside
    /// this bounded projection and is refused rather than guessed.
    public func modernConstructionContract() throws -> LegacyModernWithinConstruction {
        let rawMaximum = maximum ?? Int(Int32.max)
        guard rawMaximum >= Int(Int32.min), rawMaximum <= Int(Int32.max) else {
            throw LegacyWithinConstructionError.maximumOutsideVerifiedSigned32BitRange
        }
        let normalized = Int32(max(0, rawMaximum))
        return .init(unit: unit ?? .character, direction: before ? .before : .within,
                     minimum: normalized == 0 ? 0 : 1, maximum: normalized)
    }
}
public enum LegacyWithinConstructionError: Error, Equatable, Sendable {
    case maximumOutsideVerifiedSigned32BitRange
}
/// Constructor configuration only. A character enum is not proof that engine
/// hit offsets use UTF-16, Unicode scalars or displayed characters.
public struct LegacyModernWithinConstruction: Equatable, Sendable {
    public enum Direction: String, Codable, Sendable { case before, within }
    public let unit: LegacyEngineDistance.Unit
    public let direction: Direction
    public let minimum: Int32
    public let maximum: Int32
}
public enum LegacyEngineConstraint: Equatable, Sendable {
    case distance(LegacyEngineDistance)
    case field(termID: String, aliasName: String)
}
public struct LegacyEngineQuery: Equatable, Sendable {
    public let expression: LegacyEngineExpression
    public let aliases: [LegacyEngineAlias]
    public let constraints: [LegacyEngineConstraint]
    public var tree: LegacyQueryTree {
        var children: [LegacyQueryTree] = []
        if !aliases.isEmpty { children.append(.init("aliases", [:], "", aliases.map { .init("alias", ["name": $0.name], $0.field) })) }
        children.append(expression.tree)
        if !constraints.isEmpty { children.append(.init("constraints", [:], "", constraints.map(\.tree))) }
        return .init("query", ["type": "libronix"], "", children)
    }
}
private extension LegacyEngineExpression {
    var tree: LegacyQueryTree {
        switch self {
        case .term(let value): return .init("term", ["id": value.id], value.text)
        case .any: return .init("term", ["match": "any"])
        case .conjunction(let values): return .init("and", [:], "", values.map(\.tree))
        case .disjunction(let values): return .init("or", [:], "", values.map(\.tree))
        case .andNot(let left, let right): return .init("and-not", [:], "", [left.tree, right.tree])
        }
    }
}
private extension LegacyEngineConstraint {
    var tree: LegacyQueryTree {
        switch self {
        case .field(let termID, let aliasName): return .init("field", ["term": termID, "name": aliasName])
        case .distance(let value):
            var attributes = ["terms": value.termIDs.joined(separator: " ")]
            if let maximum = value.maximum { attributes["max"] = String(maximum) }
            if let unit = value.unit { attributes["unit"] = unit.rawValue }
            if value.before { attributes["type"] = "before" }
            return .init("within", attributes)
        }
    }
}

public enum LegacyQueryParser {
    public static func parse(_ source: String, dialect: LegacyQueryDialect,
                             limits: LegacyQueryLimits = .init()) throws -> LegacyParsedQuery {
        let zero = SearchTextRange(location: 0, length: 0)
        guard (1...1_048_576).contains(limits.maximumSourceUTF16), (1...4_096).contains(limits.maximumTokens),
              (1...65_536).contains(limits.maximumOperandUTF16), (1...8_192).contains(limits.maximumNodes),
              (1...128).contains(limits.maximumNesting), (1...256).contains(limits.maximumASTDepth) else {
            throw LegacyQueryError(.invalidLimits, zero)
        }
        guard source.utf16.count <= limits.maximumSourceUTF16 else {
            throw LegacyQueryError(.sourceLimit, .init(location: 0, length: source.utf16.count))
        }
        var lexer = Lexer(source, limits)
        let tokens = try lexer.scan()
        var parser = Parser(tokens, dialect, limits)
        let expression = try parser.parse()
        return .init(source: source, dialect: dialect, expression: expression)
    }
    public static func translateAdvanced(_ query: LegacyParsedQuery) throws -> LegacyEngineQuery {
        guard query.dialect == .advanced else { throw LegacyQueryError(.advancedQueryRequired, .init(location: 0, length: 0)) }
        var translation = Translation()
        let (expression, _) = translation.walk(query.expression)
        return .init(expression: expression, aliases: translation.aliases, constraints: translation.constraints)
    }

    private struct Token {
        let text: String
        let range: SearchTextRange
        let quoted: Bool
        var name: String { quoted ? "" : text.uppercased() }
    }
    private struct Lexer {
        let scalars: [Unicode.Scalar]
        let offsets: [Int]
        let limits: LegacyQueryLimits
        var cursor = 0
        init(_ source: String, _ limits: LegacyQueryLimits) {
            scalars = Array(source.unicodeScalars); self.limits = limits
            var offsets = [0]
            for scalar in scalars { offsets.append(offsets.last! + (scalar.value > 0xffff ? 2 : 1)) }
            self.offsets = offsets
        }
        func range(_ start: Int, _ end: Int) -> SearchTextRange { .init(location: offsets[start], length: offsets[end] - offsets[start]) }
        mutating func scan() throws -> [Token] {
            var tokens: [Token] = []
            while cursor < scalars.count {
                if CharacterSet.whitespacesAndNewlines.contains(scalars[cursor]) { cursor += 1; continue }
                let start = cursor
                let text: String, quoted: Bool
                if scalars[cursor] == "(" || scalars[cursor] == ")" || scalars[cursor] == ":" {
                    cursor += 1; text = String(scalars[start]); quoted = false
                } else if scalars[cursor] == "\"" {
                    cursor += 1
                    while cursor < scalars.count {
                        if scalars[cursor] == "\"" {
                            var count = 0, previous = cursor - 1
                            while previous >= start && scalars[previous] == "\\" { count += 1; previous -= 1 }
                            if count % 2 == 0 { break }
                        }
                        cursor += 1
                    }
                    guard cursor < scalars.count else { throw LegacyQueryError(.unterminatedQuote, range(start, cursor)) }
                    text = String(String.UnicodeScalarView(scalars[(start + 1)..<cursor])); quoted = true; cursor += 1
                } else {
                    while cursor < scalars.count && !CharacterSet.whitespacesAndNewlines.contains(scalars[cursor])
                        && scalars[cursor] != "(" && scalars[cursor] != ")" && scalars[cursor] != ":" && scalars[cursor] != "\"" { cursor += 1 }
                    text = String(String.UnicodeScalarView(scalars[start..<cursor])); quoted = false
                }
                let span = range(start, cursor)
                guard span.length <= limits.maximumOperandUTF16 else { throw LegacyQueryError(.operandLimit, span) }
                tokens.append(.init(text: text, range: span, quoted: quoted))
                guard tokens.count <= limits.maximumTokens else { throw LegacyQueryError(.tokenLimit, span) }
            }
            return tokens
        }
    }
    private struct Parser {
        let tokens: [Token]
        let dialect: LegacyQueryDialect
        let limits: LegacyQueryLimits
        var cursor = 0, nodes = 0
        var advanced: Bool { dialect == .advanced }
        var endRange: SearchTextRange { .init(location: tokens.last?.range.upperBound ?? 0, length: 0) }
        init(_ tokens: [Token], _ dialect: LegacyQueryDialect, _ limits: LegacyQueryLimits) {
            self.tokens = tokens; self.dialect = dialect; self.limits = limits
        }
        mutating func take() throws -> Token {
            guard tokens.indices.contains(cursor) else { throw LegacyQueryError(.missingOperand, endRange) }
            defer { cursor += 1 }; return tokens[cursor]
        }
        mutating func node(_ value: LegacyQueryExpression, _ range: SearchTextRange) throws -> LegacyQueryExpression {
            nodes += 1
            guard nodes <= limits.maximumNodes else { throw LegacyQueryError(.nodeLimit, range) }
            guard value.depth <= limits.maximumASTDepth else { throw LegacyQueryError(.astDepthLimit, range) }
            return value
        }
        mutating func leaf(_ token: Token, field: String? = nil) throws -> LegacyQueryExpression {
            guard !["(", ")", ":"].contains(token.text), !["XOR", "AND", "OR", "NEAR", "BEFORE", "WITHIN"].contains(token.name) else {
                throw LegacyQueryError(.expectedTerm, token.range)
            }
            return try node(.term(.init(text: token.text, sourceRange: token.range, quoted: token.quoted, field: field)), token.range)
        }
        mutating func atom(_ nesting: Int) throws -> LegacyQueryExpression {
            guard nesting <= limits.maximumNesting else { throw LegacyQueryError(.nestingLimit, tokens.indices.contains(cursor) ? tokens[cursor].range : endRange) }
            let token = try take()
            if token.text == "(" && !token.quoted {
                let value = try expression(1, nesting + 1)
                guard try take().text == ")" else { throw LegacyQueryError(.missingClose, token.range) }
                return value
            }
            if advanced && token.name == "NOT" { return try node(.negation(token.range, atom(nesting + 1)), token.range) }
            if tokens.indices.contains(cursor) && tokens[cursor].text == ":" && !tokens[cursor].quoted {
                guard advanced && !token.quoted else { throw LegacyQueryError(.fieldsUnavailable, token.range) }
                _ = try take(); return try leaf(take(), field: token.text)
            }
            return try leaf(token)
        }
        func op(_ token: Token) -> (Int, LegacyQueryBinaryKind)? {
            switch token.name {
            case "OR": return (1, .disjunction)
            case "AND": return (2, .conjunction)
            case "NOT": return advanced ? (2, .andNot) : nil
            case "NEAR": return (advanced ? 3 : 2, .near)
            case "BEFORE": return (advanced ? 3 : 2, .before)
            case "WITHIN": return (3, .within)
            default: return nil
            }
        }
        mutating func expression(_ minimum: Int, _ nesting: Int = 0) throws -> LegacyQueryExpression {
            var left = try atom(nesting)
            while tokens.indices.contains(cursor), let (priority, initialKind) = op(tokens[cursor]) {
                let token = tokens[cursor]
                if initialKind == .within && !advanced { throw LegacyQueryError(.withinUnavailable, token.range) }
                if priority < minimum { break }
                _ = try take(); var kind = initialKind, range = token.range
                var distance: Int?, unit: LegacyQueryDistanceUnit?
                if !advanced && kind == .conjunction && tokens.indices.contains(cursor) && tokens[cursor].name == "NOT" {
                    _ = try take(); kind = .andNot
                }
                if kind == .within {
                    let maximum = try take(), unitToken = try take()
                    guard !maximum.quoted && !maximum.text.isEmpty && maximum.text.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
                          let number = Int(maximum.text), let verifiedUnit = LegacyQueryDistanceUnit(rawValue: unitToken.text) else {
                        throw LegacyQueryError(.unsupportedProximityParameters, maximum.range)
                    }
                    distance = number; unit = verifiedUnit
                    range = .init(location: token.range.location, length: unitToken.range.upperBound - token.range.location)
                }
                let right = try expression(priority + 1, nesting + 1)
                left = try node(.binary(.init(kind: kind, sourceRange: range, maximumDistance: distance, distanceUnit: unit), left, right), range)
            }
            return left
        }
        mutating func parse() throws -> LegacyQueryExpression {
            guard !tokens.isEmpty else { throw LegacyQueryError(.emptyQuery, endRange) }
            let explicit = tokens.contains { ["AND", "OR", "NEAR", "BEFORE", "WITHIN"].contains($0.name) || (!$0.quoted && ["(", ")", ":"].contains($0.text)) }
            if !explicit && !(advanced && tokens.contains { $0.name == "NOT" }) {
                var values: [LegacyQueryExpression] = []
                for token in tokens { values.append(try leaf(token)) }
                if values.count == 1 { return values[0] }
                if advanced { return try node(.natural(values), tokens[0].range) }
                var result = values[0]
                for value in values.dropFirst() {
                    result = try node(.binary(.init(kind: .disjunction, sourceRange: .init(location: 0, length: 0), maximumDistance: nil, distanceUnit: nil), result, value), tokens[0].range)
                }
                return result
            }
            let result = try expression(1)
            guard cursor == tokens.count else { throw LegacyQueryError(.unexpectedToken, tokens[cursor].range) }
            return result
        }
    }
    private struct Translation {
        var terms = 0
        var aliases: [LegacyEngineAlias] = []
        var constraints: [LegacyEngineConstraint] = []
        mutating func walk(_ source: LegacyQueryExpression) -> (LegacyEngineExpression, [String]) {
            switch source {
            case .term(let value):
                terms += 1; let id = "auto\(terms)"
                if let field = value.field {
                    let name = "alias\(aliases.count + 1)"; aliases.append(.init(name: name, field: field))
                    constraints.append(.field(termID: id, aliasName: name))
                }
                return (.term(.init(id: id, text: value.text)), [id])
            case .negation(_, let value):
                let (child, ids) = walk(value); return (.andNot(.any, child), ids)
            case .natural(let values):
                var children: [LegacyEngineExpression] = [], ids: [String] = []
                for value in values { let (child, termIDs) = walk(value); children.append(child); ids += termIDs }
                return (.conjunction(children), ids)
            case .binary(let op, let left, let right):
                let (lhs, lhsIDs) = walk(left), (rhs, rhsIDs) = walk(right), ids = lhsIDs + rhsIDs
                switch op.kind {
                case .disjunction: return (.disjunction([lhs, rhs]), ids)
                case .andNot: return (.andNot(lhs, rhs), ids)
                case .near: constraints.append(.distance(.init(termIDs: ids, maximum: 48, unit: nil, before: false)))
                case .before: constraints.append(.distance(.init(termIDs: ids, maximum: nil, unit: nil, before: true)))
                case .within:
                    constraints.append(.distance(.init(termIDs: ids, maximum: op.maximumDistance,
                        unit: op.distanceUnit == .words ? .word : .character, before: false)))
                case .conjunction: break
                }
                if op.kind == .conjunction, case .andNot(.any, let negative) = rhs { return (.andNot(lhs, negative), ids) }
                var children: [LegacyEngineExpression] = []
                for child in [lhs, rhs] {
                    if case .conjunction(let values) = child { children += values } else { children.append(child) }
                }
                return (.conjunction(children), ids)
            }
        }
    }
}
