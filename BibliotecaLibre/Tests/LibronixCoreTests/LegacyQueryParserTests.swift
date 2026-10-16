import Foundation
import Testing
@testable import LibronixCore

@Suite struct LegacyQueryParserTests {
    private func error(_ query: String, _ dialect: LegacyQueryDialect = .advanced,
                       _ limits: LegacyQueryLimits = .init()) -> LegacyQueryError? {
        do { _ = try LegacyQueryParser.parse(query, dialect: dialect, limits: limits); Issue.record("Expected controlled query error"); return nil }
        catch let value as LegacyQueryError { return value }
        catch { Issue.record("Unexpected parser failure: \(error)"); return nil }
    }

    @Test func originalDialectsKeepAdjacencyAndNOTMeaningSeparate() throws {
        let basic = try LegacyQueryParser.parse("Dios amor", dialect: .basic)
        let advanced = try LegacyQueryParser.parse("Dios amor", dialect: .advanced)
        #expect(basic.tree.children.first?.tag == "or")
        #expect(advanced.tree.children.first?.tag == "natural")
        #expect(try LegacyQueryParser.translateAdvanced(advanced).tree.children.first?.tag == "and")
        #expect(try LegacyQueryParser.parse("NOT Dios", dialect: .basic).tree.children.first?.tag == "or")
        #expect(try LegacyQueryParser.parse("NOT Dios", dialect: .advanced).tree.children.first?.tag == "not")
        #expect(try LegacyQueryParser.parse("Dios NOT amor", dialect: .advanced).tree.children.first?.tag == "and-not")
        #expect(error("Dios NOT amor OR fe", .basic)?.code == .unexpectedToken)
        #expect(error("Dios OR NOT amor", .basic) != nil)
    }

    @Test func mixedProximityPrecedenceMatchesEachObservedDialect() throws {
        let basic = try LegacyQueryParser.parse("Dios AND amor NEAR fe", dialect: .basic).tree
        let advanced = try LegacyQueryParser.parse("Dios AND amor NEAR fe", dialect: .advanced).tree
        #expect(basic.children.first?.tag == "near")
        #expect(basic.children.first?.children.first?.tag == "and")
        #expect(advanced.children.first?.tag == "and")
        #expect(advanced.children.first?.children.last?.tag == "near")
        #expect(try LegacyQueryParser.parse("Dios or amor", dialect: .advanced).tree.children.first?.tag == "or")
        let literal = try LegacyQueryParser.parse("Dios NEAR/3 amor", dialect: .advanced)
        #expect(literal.tree.children.first?.tag == "natural")
        #expect(literal.tree.children.first?.children[1].text == "NEAR/3")
    }

    @Test func advancedCoordinatesRetainUTF16QuotesCombiningMarksFieldsAndLiteralEscapes() throws {
        let emoji = try LegacyQueryParser.parse("\"😀\" AND x", dialect: .advanced).tree.children[0]
        #expect(emoji.attributes == ["offset": "5", "length": "3"])
        #expect(emoji.children[0].attributes == ["offset": "0", "length": "4"])
        #expect(emoji.children[1].attributes["offset"] == "9")
        let combining = try LegacyQueryParser.parse("\"café\" AND x", dialect: .advanced).tree.children[0]
        #expect(combining.attributes["offset"] == "8")
        #expect(combining.children[0].text == "café")
        #expect(combining.children[0].attributes["length"] == "7")
        let field = try LegacyQueryParser.parse("foo:\"😀\"", dialect: .advanced).tree.children[0]
        #expect(field.attributes == ["offset": "4", "length": "4", "fields": "1", "field1": "foo"])
        #expect(try LegacyQueryParser.parse(#""a\"b""#, dialect: .advanced).tree.children[0].text == #"a\"b"#)
        #expect(error("foo:bar", .basic)?.code == .fieldsUnavailable)
    }

    @Test func translationPreservesUnknownUnitsFieldAliasesAndNegationNormalization() throws {
        let near = try LegacyQueryParser.translateAdvanced(LegacyQueryParser.parse("Dios NEAR amor", dialect: .advanced))
        guard let first = near.constraints.first, case let .distance(distance) = first else { Issue.record("Missing proximity constraint"); return }
        #expect(distance.maximum == 48 && distance.unit == nil && !distance.before)
        #expect(distance.termIDs == ["auto1", "auto2"])
        let modernNear = try distance.modernConstructionContract()
        #expect(modernNear.unit == .character && modernNear.direction == .within)
        #expect(modernNear.minimum == 1 && modernNear.maximum == 48)
        let field = try LegacyQueryParser.translateAdvanced(LegacyQueryParser.parse("foo:bar", dialect: .advanced))
        #expect(field.aliases.first?.name == "alias1" && field.aliases.first?.field == "foo")
        #expect(field.constraints == [.field(termID: "auto1", aliasName: "alias1")])
        let zero = try LegacyQueryParser.translateAdvanced(LegacyQueryParser.parse("Dios WITHIN 0 WORDS amor", dialect: .advanced))
        guard let zeroFirst = zero.constraints.first, case let .distance(zeroDistance) = zeroFirst else { Issue.record("Missing explicit distance"); return }
        #expect(zeroDistance.maximum == 0 && zeroDistance.unit == .word)
        let modernZero = try zeroDistance.modernConstructionContract()
        #expect(modernZero.minimum == 0 && modernZero.maximum == 0 && modernZero.unit == .word)
        let unlimitedBefore = LegacyEngineDistance(termIDs: ["auto1", "auto2"], maximum: nil, unit: nil, before: true)
        let modernBefore = try unlimitedBefore.modernConstructionContract()
        #expect(modernBefore.unit == .character && modernBefore.direction == .before)
        #expect(modernBefore.minimum == 1 && modernBefore.maximum == Int32.max)
        let overflow = LegacyEngineDistance(termIDs: [], maximum: Int(Int32.max) + 1, unit: nil, before: false)
        #expect(throws: LegacyWithinConstructionError.self) { try overflow.modernConstructionContract() }
        let negative = try LegacyQueryParser.translateAdvanced(LegacyQueryParser.parse("Dios AND NOT amor", dialect: .advanced)).tree
        #expect(negative.children[0].tag == "and-not")
        #expect(negative.children[0].children.map(\.attributes) == [["id": "auto1"], ["id": "auto2"]])
        #expect(throws: LegacyQueryError.self) { try LegacyQueryParser.translateAdvanced(LegacyQueryParser.parse("Dios", dialect: .basic)) }
    }

    @Test func malformedInputsAndNumericOverflowCannotProducePartialTrees() {
        #expect(error("")?.code == .emptyQuery)
        #expect(error("\"unfinished")?.code == .unterminatedQuote)
        #expect(error("Dios AND")?.code == .missingOperand)
        #expect(error("Dios)")?.code == .unexpectedToken)
        #expect(error("foo:")?.code == .missingOperand)
        #expect(error("Dios WITHIN -1 WORDS amor")?.code == .unsupportedProximityParameters)
        #expect(error("Dios WITHIN 99999999999999999999999999 WORDS amor")?.code == .unsupportedProximityParameters)
        #expect(error("Dios WITHIN 2 UNVERIFIED amor")?.code == .unsupportedProximityParameters)
        #expect(error("Dios WITHIN 2 WORDS amor", .basic)?.code == .withinUnavailable)
    }

    @Test func budgetsBoundSourceOperandsTokensASTAndRecursionWithoutChangingStrictGrammar() throws {
        #expect(error("\"😀\"", .advanced, .init(maximumSourceUTF16: 3))?.code == .sourceLimit)
        #expect(error("\"😀😀\"", .advanced, .init(maximumOperandUTF16: 5))?.code == .operandLimit)
        #expect(error("a b c", .basic, .init(maximumTokens: 2))?.code == .tokenLimit)
        #expect(error("a AND b", .advanced, .init(maximumNodes: 2))?.code == .nodeLimit)
        #expect(error("(((a)))", .advanced, .init(maximumNesting: 2))?.code == .nestingLimit)
        #expect(error("a b c d e", .basic, .init(maximumASTDepth: 3))?.code == .astDepthLimit)
        #expect(error("a", .advanced, .init(maximumTokens: Int.max))?.code == .invalidLimits)
        #expect(throws: SearchQueryError.self) { try SearchQueryParser.parse("Dios amor") }
        #expect(throws: SearchQueryError.self) { try SearchQueryParser.parse("Dios NEAR amor") }
        #expect(throws: SearchQueryError.self) { try SearchQueryParser.parse("foo:bar") }
    }
}
