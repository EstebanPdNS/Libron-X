import Foundation
import Testing
@testable import LibronixCore

struct TextComparisonTests {
    @Test func additionsOmissionsAndSubstitutionsRetainOriginalRanges() throws {
        let a = "In the beginning was the Word.", b = "In beginning was a living Word!"
        let result = try TextComparison.differences(base: a, compared: b)
        #expect(result.map(\.kind) == [.omission, .substitution, .substitution])
        #expect(result.map { (a as NSString).substring(with: $0.base.nsRange) } == ["the", "the", "."])
        #expect(result.map { (b as NSString).substring(with: $0.compared.nsRange) } == ["", "a living", "!"])
        let added = try TextComparison.differences(base: "Word", compared: "The Word lives")
        #expect(added.map(\.kind) == [.addition, .addition])
        #expect(try TextComparison.differences(base: "", compared: "😀").first?.compared.length == 2)
        #expect(try TextComparison.differences(base: "שלום", compared: "").first?.kind == .omission)
    }
    @Test func optionsAreIndependentAndNeverRewriteUnicodeCoordinates() throws {
        var options = TextComparisonOptions()
        let base = "😀 ÁRBOL, λόγος שָׁלוֹם 👩🏽‍💻", compared = "😀 árbol λόγος שָׁלוֹם 👨🏽‍💻"
        let all = try TextComparison.differences(base: base, compared: compared, options: options)
        #expect(all.count == 2)
        options.caseSensitive = false
        let caseFolded = try TextComparison.differences(base: base, compared: compared, options: options)
        #expect(caseFolded.first?.kind == .omission)
        options.punctuationSensitive = false
        let remaining = try TextComparison.differences(base: base, compared: compared, options: options)
        #expect(remaining.count == 1)
        #expect(remaining.map { (base as NSString).substring(with: $0.base.nsRange) } == ["👩🏽‍💻"])
        #expect(remaining.map { (compared as NSString).substring(with: $0.compared.nsRange) } == ["👨🏽‍💻"])
        #expect(try !TextComparison.differences(base: "λόγος", compared: "λογος", options: options).isEmpty)
        options.accentSensitive = false
        #expect(try TextComparison.differences(base: "λόγος", compared: "λογος", options: options).isEmpty)
        #expect(try TextComparison.differences(base: "é", compared: "e\u{301}").isEmpty)
        #expect(try TextComparison.differences(base: "one\n  two", compared: "one two").isEmpty)
    }
    @Test func limitsAreExplicitAndCancelledWorkDoesNotReturnAReport() async throws {
        #expect(throws: TextComparisonError.self) {
            try TextComparison.differences(base: String(repeating: "word ", count: 2500), compared: String(repeating: "term ", count: 2500))
        }
        let task = Task { try Task.checkCancellation(); return try TextComparison.differences(base: "word", compared: "term") }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled comparison returned a result") }
        catch is CancellationError {}
    }
    @Test func ignoringPunctuationRetainsSymbolsAndEmojiInOptimizedBuilds() throws {
        var options = TextComparisonOptions(); options.punctuationSensitive = false
        #expect(try TextComparison.differences(base: "Word.", compared: "Word!", options: options).isEmpty)
        #expect(try TextComparison.differences(base: "«word»—", compared: "word", options: options).isEmpty)
        #expect(try !TextComparison.differences(base: "$", compared: "€", options: options).isEmpty)
        let differences = try TextComparison.differences(base: "👩🏽‍💻", compared: "👨🏽‍💻", options: options)
        #expect(differences.count == 1 && differences[0].base.length == "👩🏽‍💻".utf16.count)
    }
}
