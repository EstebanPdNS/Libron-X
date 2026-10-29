import Foundation
import Testing
@testable import LibronixCore

struct BibleCopyOutputBudgetTests {
    private func style() -> BibleCopyOutputStyle {
        var value = BibleCopyOutputStyle(name: "Authored budget test")
        value.citation = false
        value.beforePassage.pattern = ""
        value.beforeVerse.pattern = ""
        value.afterVerse.pattern = ""
        value.afterPassage.pattern = ""
        return value
    }

    private func document(_ texts: [String], citation: String = "") throws -> BibleCopyDocument {
        let verses = try texts.enumerated().map { index, text in
            let reference = "Xy 1:\(index + 1)"
            let address = BibleCopyAddress(try #require(LegacyPassageQuery.parse(reference)))
            let span = SearchTextRange(location: 0, length: text.utf16.count)
            return BibleCopyVerse(address: address, sourceReference: reference,
                source: ReaderOutputSource(sectionOrdinal: index, decodedTextSHA256: LibrarySearchService.textFingerprint(text), selectedRange: span),
                paragraphKey: String(index), paragraphStyle: nil,
                fragments: [.init(text: text, style: nil, sourceRange: span, footnote: nil, isBibleText: true, isVerseNumber: false)])
        }
        var value = BibleCopyDocument(resourceID: "owned-budget-test", passage: try .parse("Xy 1"), title: "Authored source",
            abbreviation: "Own", verses: verses, footnotes: [], citation: citation,
            typography: .init(version: 1, fontGroupVersion: 1, fontGroups: [], characterStyles: [], paragraphStyles: [], opaqueTail: Data()),
            sources: verses.map(\.source), fullParagraphs: [], sourceLanguages: ["en"])
        value.sourceParagraphs = verses.map {
            .init(style: nil, fragments: $0.fragments, marks: [.init(offset: 0, address: $0.address)])
        }
        return value
    }

    private func context(abbreviation: String, book: String = "Own", reference: String = "Own 1:3") -> BibleCopyOutputTemplateContext {
        .init(passage: "Own 1", fullReference: reference, shortReference: "O 1:3", fullBook: book,
            shortBook: "O", chapter: 1, verse: 3, abbreviation: abbreviation)
    }

    @Test func sequentialReplacementAndUnicodeStayLiteralWithinTheBudget() throws {
        let supplied = context(abbreviation: "^B^B", book: "Z", reference: "<b>^v</b>")
        #expect(try BibleCopyOutputTemplateExpander.expand("^a|^R|^^|^?", context: supplied, maximumUTF16Units: 64) == "ZZ|<b>3</b>|^|^?")
        let emoji = context(abbreviation: "🦉🦉")
        #expect(try BibleCopyOutputTemplateExpander.expand("^a", context: emoji, maximumUTF16Units: 4) == "🦉🦉")
        #expect(throws: BibleCopyError.limitExceeded) {
            try BibleCopyOutputTemplateExpander.expand("^a", context: emoji, maximumUTF16Units: 3)
        }
        let runs = try BibleCopyFormatter.templateRuns(.init("<b>^a</b><i>^a</i>"), context: context(abbreviation: "🦉"), maximumUTF16Units: 4)
        #expect(runs.map(\.text) == ["🦉", "🦉"] && runs[0].format.bold && runs[1].format.italic)
        #expect(throws: BibleCopyError.limitExceeded) {
            try BibleCopyFormatter.templateRuns(.init("<b>^a</b><i>^a</i>"), context: context(abbreviation: "🦉"), maximumUTF16Units: 3)
        }
        #expect(try BibleCopyFormatter.templateRuns(.init("<b>^a</b>"), context: nil, maximumUTF16Units: 0).isEmpty)
    }

    @Test func intermediateExpansionIsBoundedEvenWhenALaterReplacementWouldShrinkIt() throws {
        // The intermediate ^c sequence has 8192 units; its final digits would have 4096.
        let supplied = context(abbreviation: String(repeating: "^B", count: 64), book: String(repeating: "^c", count: 64))
        #expect(throws: BibleCopyError.limitExceeded) {
            try BibleCopyOutputTemplateExpander.expand("^a", context: supplied, maximumUTF16Units: 4096)
        }
    }

    @Test func aggregateBudgetIncludesInterVerseSpacesAndCountsTheTrimmedUnicodeBody() throws {
        let source = try document(["  🦉  ", "Q"]), original = source
        let output = try BibleCopyFormatter.format(source, style: style(), maximumUTF16Units: 4)
        #expect(output.plainText == "🦉 Q" && source == original)
        #expect(throws: BibleCopyError.limitExceeded) {
            try BibleCopyFormatter.format(source, style: style(), maximumUTF16Units: 3)
        }
    }

    @Test(arguments: [true, false])
    func sourceParagraphSeparatorsAndPassageTemplatesShareTheBudget(bibleOnly: Bool) throws {
        let source = try document(["A", "B"])
        var policy = style()
        policy.bibleTextOnly = bibleOnly; policy.paragraphs = .sourceParagraphs
        policy.beforePassage.pattern = "<b>X</b>"; policy.afterPassage.pattern = "Z"
        let expected = bibleOnly ? "XA\n\nBZ" : "X\n\nA\n\nB\n\nZ"
        let output = try BibleCopyFormatter.format(source, style: policy, maximumUTF16Units: expected.utf16.count)
        #expect(output.plainText == expected)
        #expect(throws: BibleCopyError.limitExceeded) {
            try BibleCopyFormatter.format(source, style: policy, maximumUTF16Units: expected.utf16.count - 1)
        }
    }

    @Test func notesAreCountedOnceAndCitationMarkersAndEndnoteSeparatorsAreIncluded() throws {
        let original = try document(["A", "B"], citation: "C")
        let verses = original.verses.map { verse in
            BibleCopyVerse(address: verse.address, sourceReference: verse.sourceReference, source: verse.source,
                paragraphKey: verse.paragraphKey, paragraphStyle: nil, fragments: verse.fragments + [
                    .init(text: "x", style: nil, sourceRange: .init(location: 1, length: 1), footnote: "owned.note", isBibleText: false, isVerseNumber: false)])
        }
        let source = BibleCopyDocument(resourceID: original.resourceID, passage: original.passage, title: original.title,
            abbreviation: original.abbreviation, verses: verses,
            footnotes: [.init(id: "owned.note", marker: "x", text: "🦉", source: original.sources[0])],
            citation: original.citation, typography: original.typography, sources: original.sources, fullParagraphs: [], sourceLanguages: ["en"])
        var policy = style(); policy.copyFootnotes = true; policy.citation = true
        let expected = "Ax Bx[1]\n\nx 🦉\n\n[1] C"
        let output = try BibleCopyFormatter.format(source, style: policy, maximumUTF16Units: expected.utf16.count)
        #expect(output.plainText == expected && output.notes.count == 2)
        #expect(throws: BibleCopyError.limitExceeded) {
            try BibleCopyFormatter.format(source, style: policy, maximumUTF16Units: expected.utf16.count - 1)
        }
        policy.copyFootnotes = false
        let withoutNotes = "A B[1]\n\n[1] C"
        #expect(try BibleCopyFormatter.format(source, style: policy, maximumUTF16Units: withoutNotes.utf16.count).plainText == withoutNotes)
        policy.citation = false
        #expect(try BibleCopyFormatter.format(source, style: policy, maximumUTF16Units: 3).plainText == "A B")
    }

    @Test func individuallyValidRepeatedTemplatesCannotExceedTheProductionAggregateLimit() throws {
        let source = try document(Array(repeating: "x", count: 1100))
        var policy = style(); policy.beforeVerse.pattern = String(repeating: "a", count: 16_000)
        try policy.validate()
        #expect(throws: BibleCopyError.limitExceeded) { try BibleCopyFormatter.format(source, style: policy) }
    }

    @Test func tinyStyledRunsCannotBypassTheElementLimitWithASmallTextResult() throws {
        let count = BibleCopyOutputBudget.maximumElements + 1
        let original = try document([String(repeating: "x", count: count)]), verse = original.verses[0]
        let fragments: [BibleCopyFragment] = (0..<count).map {
            .init(text: "x", style: nil, sourceRange: .init(location: $0, length: 1), footnote: nil, isBibleText: true, isVerseNumber: false)
        }
        let splitVerse = BibleCopyVerse(address: verse.address, sourceReference: verse.sourceReference, source: verse.source,
            paragraphKey: verse.paragraphKey, paragraphStyle: nil, fragments: fragments)
        let source = BibleCopyDocument(resourceID: original.resourceID, passage: original.passage, title: original.title,
            abbreviation: original.abbreviation, verses: [splitVerse], footnotes: [], citation: "", typography: original.typography,
            sources: original.sources, fullParagraphs: [], sourceLanguages: ["en"])
        #expect(throws: BibleCopyError.limitExceeded) { try BibleCopyFormatter.format(source, style: style()) }
    }

    @Test func citationOnlyCopiesAndInvalidBudgetsUseTheSameContract() throws {
        let source = try document([], citation: "🦉")
        var policy = style(); policy.citation = true
        #expect(try BibleCopyFormatter.format(source, style: policy, maximumUTF16Units: 8).plainText == "\n\n[1] 🦉")
        for limit in [-1, 7, Int.max] {
            #expect(throws: BibleCopyError.limitExceeded) { try BibleCopyFormatter.format(source, style: policy, maximumUTF16Units: limit) }
        }
        #expect(throws: BibleCopyError.limitExceeded) {
            try BibleCopyOutputTemplateExpander.expand(String(repeating: "x", count: 16_385), context: nil)
        }
    }

    @Test func cancelledFormattingAndExpansionReturnCancellationInsteadOfAResult() async throws {
        let source = try document(["Owned text"]), policy = style()
        let formatting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BibleCopyFormatter.format(source, style: policy)
        }
        await #expect(throws: CancellationError.self) { try await formatting.value }
        let expansion = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BibleCopyOutputTemplateExpander.expand("^a", context: nil)
        }
        await #expect(throws: CancellationError.self) { try await expansion.value }
    }
}
