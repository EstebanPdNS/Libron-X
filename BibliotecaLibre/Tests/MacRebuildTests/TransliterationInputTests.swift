import Testing
@testable import MacRebuild

struct TransliterationInputTests {
    @Test func textConvertsWithoutChangingTheInput() {
        let greek = "Αὑ", hebrew = "בִי"
        #expect(TransliterationInput.convert(greek, language: .greek) == "Hau")
        #expect(TransliterationInput.convert(hebrew, language: .hebrew) == "bî")
        #expect(greek == "Αὑ" && hebrew == "בִי")
    }
    @Test func boundedInputRejectsOversizedAndNullCharacters() {
        #expect(TransliterationInput.convert(String(repeating: "a", count: 4097), language: .greek) == nil)
        #expect(TransliterationInput.convert("a\0b", language: .hebrew) == nil)
        #expect(TransliterationInput.convert("", language: .greek) == "")
    }
}
