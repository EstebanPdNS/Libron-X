import Foundation
import Testing
@testable import LibronixCore

@Suite struct SearchQueryParserTests {
    private func error(_ source: String, limits: SearchQueryLimits = .init()) -> SearchQueryError? {
        do { _ = try SearchQueryParser.parse(source, limits: limits); Issue.record("Expected query error"); return nil }
        catch let error as SearchQueryError { return error }
        catch { Issue.record("Unexpected error: \(error)"); return nil }
    }

    @Test func precedenceAndExplicitParenthesesBuildDifferentASTs() throws {
        let query = try SearchQueryParser.parse("faith OR hope AND NOT fear")
        guard case let .disjunction(.term(faith), .conjunction(.term(hope), .negation(.term(fear)))) = query.expression else {
            Issue.record("Wrong explicit precedence"); return
        }
        #expect(faith.text == "faith")
        #expect(hope.sourceRange == SearchTextRange(location: 9, length: 4))
        #expect(fear.text == "fear")
        let grouped = try SearchQueryParser.parse("(faith OR hope) AND NOT fear")
        guard case .conjunction(.disjunction, .negation) = grouped.expression else {
            Issue.record("Parentheses did not preserve grouping"); return
        }
    }

    @Test func unicodeAndQuotedEscapesKeepOriginalUTF16SourceSpans() throws {
        let query = try SearchQueryParser.parse("\"😀\" OR λόγος")
        guard case let .disjunction(.phrase(emoji), .term(greek)) = query.expression else {
            Issue.record("Expected phrase and term"); return
        }
        #expect(emoji.sourceRange == SearchTextRange(location: 0, length: 4))
        #expect(greek.sourceRange.location == 8)
        #expect(greek.sourceRange.length == 6)
        let escaped = try SearchQueryParser.parse(#""say \"amen\" \\ today""#)
        guard case let .phrase(operand) = escaped.expression else { Issue.record("Expected phrase"); return }
        #expect(operand.text == #"say "amen" \ today"#)
    }

    @Test func operatorsAreExplicitAndUppercaseWordsRemainSearchableWhenQuoted() throws {
        #expect(error("faith hope")?.code == .expectedOperator)
        #expect(error("faith NOT fear")?.code == .expectedOperator)
        #expect(error("faith AND")?.code == .missingOperand)
        #expect(error("AND faith")?.code == .missingOperand)
        #expect(error("faith OR OR hope")?.range == SearchTextRange(location: 9, length: 2))
        guard case let .term(word) = try SearchQueryParser.parse("and").expression else { Issue.record("Expected term"); return }
        #expect(word.text == "and")
        guard case .phrase = try SearchQueryParser.parse("\"AND\"").expression else { Issue.record("Expected literal"); return }
    }

    @Test func unmatchedParenthesesAndPhraseErrorsPointAtActualInput() {
        #expect(error(" ")?.code == .emptyQuery)
        #expect(error("(faith")?.range == SearchTextRange(location: 0, length: 1))
        #expect(error("(faith")?.code == .unclosedParenthesis)
        #expect(error("faith)")?.code == .unexpectedClosingParenthesis)
        #expect(error(")")?.code == .unexpectedClosingParenthesis)
        #expect(error("()")?.code == .missingOperand)
        #expect(error("\"faith")?.code == .unterminatedPhrase)
        #expect(error("\" \"")?.code == .emptyPhrase)
        #expect(error(#""bad\n""#)?.code == .invalidEscape)
        #expect(error("\"😀\" OR )")?.range == SearchTextRange(location: 8, length: 1))
    }

    @Test(arguments: ["faith NEAR hope", "faith NEAR/2 hope", "faith BEFORE hope", "faith WITHIN hope",
                       "faith XOR hope", "lemma:λόγος", "faith*", "faith?", "a && b", "a-b", "[field]", "“faith”"])
    func unverifiedAdvancedSyntaxIsNeverSilentlySearchedAsText(source: String) {
        #expect(error(source)?.code == .unsupportedSyntax)
    }

    @Test func sourceOperandNodeAndNestingBudgetsAreEnforcedBeforeDeepRecursion() {
        #expect(error("\"😀\"", limits: .init(maximumSourceUTF16: 3))?.code == .sourceLimit)
        #expect(error("peace", limits: .init(maximumOperandUTF16: 4))?.code == .operandLimit)
        #expect(error("\"😀😀\"", limits: .init(maximumOperandUTF16: 3))?.code == .operandLimit)
        #expect(error("a AND b", limits: .init(maximumNodes: 2))?.code == .nodeLimit)
        #expect(error("(((a)))", limits: .init(maximumNesting: 2))?.code == .nestingLimit)
        #expect(error("NOT NOT NOT a", limits: .init(maximumNesting: 2))?.code == .nestingLimit)
        #expect(error("a", limits: .init(maximumNodes: Int.max))?.code == .invalidLimits)
        #expect(error("a", limits: .init(maximumNesting: Int.max))?.code == .invalidLimits)
        #expect(error("a", limits: .init(maximumSourceUTF16: 0))?.code == .invalidLimits)
    }
}
