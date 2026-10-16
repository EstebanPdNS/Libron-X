import Foundation

/// Half-open offsets in the original UTF-16 string, never Swift Character counts.
public struct SearchTextRange: Hashable, Sendable, Codable {
    public let location: Int
    public let length: Int
    public var upperBound: Int { location + length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct SearchTextOperand: Hashable, Sendable {
    public let text: String
    public let sourceRange: SearchTextRange

    public init(text: String, sourceRange: SearchTextRange) {
        self.text = text
        self.sourceRange = sourceRange
    }
}

/// Independent, deliberately limited grammar. Original-engine textual grammar
/// and precedence still require recorded fixtures; this AST does not claim them.
public indirect enum SearchExpression: Hashable, Sendable {
    case term(SearchTextOperand)
    case phrase(SearchTextOperand)
    case conjunction(SearchExpression, SearchExpression)
    case disjunction(SearchExpression, SearchExpression)
    case negation(SearchExpression)
}

public struct SearchQuery: Hashable, Sendable {
    public let source: String
    public let expression: SearchExpression

    // Constructed through the bounded parser; callers cannot bypass its limits.
    init(source: String, expression: SearchExpression) {
        self.source = source
        self.expression = expression
    }
}

public struct SearchQueryLimits: Hashable, Sendable {
    public var maximumSourceUTF16: Int
    public var maximumOperandUTF16: Int
    public var maximumNodes: Int
    public var maximumNesting: Int

    public init(maximumSourceUTF16: Int = 16_384,
                maximumOperandUTF16: Int = 512,
                maximumNodes: Int = 512,
                maximumNesting: Int = 32) {
        self.maximumSourceUTF16 = maximumSourceUTF16
        self.maximumOperandUTF16 = maximumOperandUTF16
        self.maximumNodes = maximumNodes
        self.maximumNesting = maximumNesting
    }
}

public struct SearchQueryError: Error, LocalizedError, Equatable, Sendable {
    public enum Code: String, Sendable {
        case emptyQuery, missingOperand, expectedOperator
        case unexpectedClosingParenthesis, unclosedParenthesis
        case unterminatedPhrase, invalidEscape, emptyPhrase, unsupportedSyntax
        case sourceLimit, operandLimit, nodeLimit, nestingLimit, invalidLimits
    }
    public let code: Code
    public let range: SearchTextRange
    public let message: String
    public var errorDescription: String? { message }

    init(_ code: Code, range: SearchTextRange, _ message: String) {
        self.code = code
        self.range = range
        self.message = message
    }
}

public enum SearchQueryParser {
    public static func parse(_ source: String,
                             limits: SearchQueryLimits = SearchQueryLimits()) throws -> SearchQuery {
        guard limits.maximumSourceUTF16 > 0, limits.maximumSourceUTF16 <= 1_048_576,
              limits.maximumOperandUTF16 > 0, limits.maximumOperandUTF16 <= 65_536,
              limits.maximumNodes > 0, limits.maximumNodes <= 1_024,
              limits.maximumNesting > 0, limits.maximumNesting <= 128 else {
            throw SearchQueryError(.invalidLimits, range: .init(location: 0, length: 0),
                                   "Query limits must be positive and within the parser's safety bounds.")
        }
        let count = source.utf16.count
        guard count <= limits.maximumSourceUTF16 else {
            throw SearchQueryError(.sourceLimit, range: .init(location: 0, length: count),
                                   "Query exceeds the UTF-16 source limit.")
        }
        var lexer = Lexer(source: source, limits: limits)
        let tokens = try lexer.scan()
        var parser = Parser(tokens: tokens, limits: limits)
        let expression = try parser.parse()
        return SearchQuery(source: source, expression: expression)
    }

    private enum TokenKind: Equatable {
        case term(String), phrase(String), and, or, not, left, right, end
    }
    private struct Token {
        let kind: TokenKind
        let range: SearchTextRange
    }

    private struct Lexer {
        let scalars: [Unicode.Scalar]
        let offsets: [Int]
        let limits: SearchQueryLimits
        var cursor = 0

        init(source: String, limits: SearchQueryLimits) {
            scalars = Array(source.unicodeScalars)
            var starts: [Int] = []
            var position = 0
            for scalar in scalars {
                starts.append(position)
                position += scalar.value > 0xFFFF ? 2 : 1
            }
            starts.append(position)
            offsets = starts
            self.limits = limits
        }

        func range(_ start: Int, _ end: Int) -> SearchTextRange {
            .init(location: offsets[start], length: offsets[end] - offsets[start])
        }

        mutating func scan() throws -> [Token] {
            var tokens: [Token] = []
            while cursor < scalars.count {
                let scalar = scalars[cursor]
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { cursor += 1; continue }
                let start = cursor
                if scalar == "(" || scalar == ")" {
                    cursor += 1
                    tokens.append(Token(kind: scalar == "(" ? .left : .right, range: range(start, cursor)))
                } else if scalar == "\"" {
                    tokens.append(try scanPhrase())
                } else {
                    while cursor < scalars.count,
                          !CharacterSet.whitespacesAndNewlines.contains(scalars[cursor]),
                          scalars[cursor] != "(", scalars[cursor] != ")", scalars[cursor] != "\"" {
                        cursor += 1
                    }
                    let text = String(String.UnicodeScalarView(scalars[start..<cursor]))
                    let kind: TokenKind
                    switch text {
                    case "AND": kind = .and
                    case "OR": kind = .or
                    case "NOT": kind = .not
                    default:
                        let operatorHead = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
                        let unsupported = ["NEAR", "WITHIN", "BEFORE", "AFTER", "FOLLOWEDBY", "PRECEDEDBY", "FOLLOWED-BY", "PRECEDED-BY", "XOR", "IMPLIES", "IFF", "ANDNOT", "AND-NOT"]
                        guard !unsupported.contains(operatorHead),
                              scalars[start..<cursor].allSatisfy({ Self.isTermScalar($0) }) else {
                            throw SearchQueryError(.unsupportedSyntax, range: range(start, cursor),
                                "Unsupported query syntax. Proximity, fields, wildcards and other advanced operators require verified contracts; quote literal punctuation.")
                        }
                        guard range(start, cursor).length <= limits.maximumOperandUTF16 else {
                            throw SearchQueryError(.operandLimit, range: range(start, cursor),
                                                   "Term exceeds the UTF-16 operand limit.")
                        }
                        kind = .term(text)
                    }
                    tokens.append(Token(kind: kind, range: range(start, cursor)))
                }
                // Operators/parentheses are bounded too, before allocating a large AST.
                guard tokens.count <= limits.maximumNodes * 3 else {
                    throw SearchQueryError(.nodeLimit, range: range(start, cursor),
                                           "Query exceeds the token budget.")
                }
            }
            tokens.append(Token(kind: .end, range: range(cursor, cursor)))
            return tokens
        }

        mutating func scanPhrase() throws -> Token {
            let start = cursor
            cursor += 1
            var phrase = String.UnicodeScalarView()
            var phraseLength = 0
            while cursor < scalars.count {
                var scalar = scalars[cursor]
                if scalar == "\"" {
                    cursor += 1
                    let text = String(phrase)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw SearchQueryError(.emptyPhrase, range: range(start, cursor),
                                               "A quoted phrase must contain text.")
                    }
                    return Token(kind: .phrase(text), range: range(start, cursor))
                }
                if scalar == "\\" {
                    let escape = cursor
                    cursor += 1
                    guard cursor < scalars.count, scalars[cursor] == "\"" || scalars[cursor] == "\\" else {
                        throw SearchQueryError(.invalidEscape, range: range(escape, min(cursor + 1, scalars.count)),
                                               "Quoted phrases support only escaped quotes and backslashes.")
                    }
                    scalar = scalars[cursor]
                }
                phrase.append(scalar)
                phraseLength += scalar.value > 0xFFFF ? 2 : 1
                guard phraseLength <= limits.maximumOperandUTF16 else {
                    throw SearchQueryError(.operandLimit, range: range(start, cursor + 1),
                                           "Phrase exceeds the UTF-16 operand limit.")
                }
                cursor += 1
            }
            throw SearchQueryError(.unterminatedPhrase, range: range(start, cursor),
                                   "Quoted phrase is missing its closing quote.")
        }

        static func isTermScalar(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
                || scalar == "'" || scalar == "’" || scalar == "_"
        }
    }

    private struct Parser {
        let tokens: [Token]
        let limits: SearchQueryLimits
        var cursor = 0
        var nodes = 0
        var current: Token { tokens[cursor] }

        mutating func parse() throws -> SearchExpression {
            guard current.kind != .end else {
                throw SearchQueryError(.emptyQuery, range: current.range, "Enter a search query.")
            }
            let expression = try parseOr(depth: 0)
            if current.kind == .right {
                throw SearchQueryError(.unexpectedClosingParenthesis, range: current.range,
                                       "Closing parenthesis has no matching opening parenthesis.")
            }
            guard current.kind == .end else {
                throw SearchQueryError(.expectedOperator, range: current.range,
                                       "Use an explicit AND or OR between expressions, or quote a phrase.")
            }
            return expression
        }

        mutating func node(_ expression: SearchExpression, at range: SearchTextRange) throws -> SearchExpression {
            nodes += 1
            guard nodes <= limits.maximumNodes else {
                throw SearchQueryError(.nodeLimit, range: range, "Query exceeds the AST node limit.")
            }
            return expression
        }

        mutating func parseOr(depth: Int) throws -> SearchExpression {
            var expression = try parseAnd(depth: depth)
            while current.kind == .or {
                let op = current; cursor += 1
                expression = try node(.disjunction(expression, parseAnd(depth: depth)), at: op.range)
            }
            return expression
        }

        mutating func parseAnd(depth: Int) throws -> SearchExpression {
            var expression = try parseUnary(depth: depth)
            while current.kind == .and {
                let op = current; cursor += 1
                expression = try node(.conjunction(expression, parseUnary(depth: depth)), at: op.range)
            }
            return expression
        }

        mutating func parseUnary(depth: Int) throws -> SearchExpression {
            guard depth <= limits.maximumNesting else {
                throw SearchQueryError(.nestingLimit, range: current.range, "Query nesting exceeds its limit.")
            }
            if current.kind == .not {
                let op = current; cursor += 1
                return try node(.negation(parseUnary(depth: depth + 1)), at: op.range)
            }
            let token = current
            switch token.kind {
            case let .term(text):
                cursor += 1
                return try node(.term(.init(text: text, sourceRange: token.range)), at: token.range)
            case let .phrase(text):
                cursor += 1
                return try node(.phrase(.init(text: text, sourceRange: token.range)), at: token.range)
            case .left:
                cursor += 1
                let expression = try parseOr(depth: depth + 1)
                guard current.kind == .right else {
                    if current.kind != .end {
                        throw SearchQueryError(.expectedOperator, range: current.range,
                                               "Use an explicit operator inside the parenthesized expression.")
                    }
                    throw SearchQueryError(.unclosedParenthesis, range: token.range,
                                           "Opening parenthesis is missing its closing parenthesis.")
                }
                cursor += 1
                return expression
            case .right where cursor == 0:
                throw SearchQueryError(.unexpectedClosingParenthesis, range: token.range,
                                       "Closing parenthesis has no matching opening parenthesis.")
            default:
                throw SearchQueryError(.missingOperand, range: token.range,
                                       "Expected a term, quoted phrase, NOT expression or opening parenthesis.")
            }
        }
    }
}
