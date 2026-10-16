import Foundation
import Testing
@testable import MacRebuild

struct ReaderErrorLocalizationTests {
    @Test(arguments: AppLanguage.allCases)
    func everyReaderFailureHasAnExplicitTranslationWithoutLosingItsMeaning(language: AppLanguage) throws {
        let failures: [RebuildError] = [.bibleReferenceTargetUnavailable, .referenceEditionUnavailable("RVR60"),
            .invalidPassagePart, .passageReadLimit, .unsupportedFormat, .referenceNotFound, .referenceSearchIncomplete]
        var messages: Set<String> = []
        for failure in failures {
            let translation = try #require(AppStrings.catalog[failure.messageKey]?[language.rawValue])
            #expect(!translation.isEmpty)
            #expect(!failure.message(language: language).contains("{edition}"))
            messages.insert(failure.message(language: language))
        }
        #expect(messages.count == failures.count)
        #expect(RebuildError.referenceSearchIncomplete.message(language: language)
            != RebuildError.referenceNotFound.message(language: language))
    }
    @Test func missingEditionIsInsertedVerbatimEvenWhenItContainsTemplateSyntaxOrMixedScripts() {
        let edition = "RVR60-{edition}-{total}-كتاب-😀"
        #expect(RebuildError.referenceEditionUnavailable(edition).message(language: .english)
            == "The reference requires edition " + edition + ". Open that edition to follow this link.")
        #expect(RebuildError.referenceEditionUnavailable(edition).message(language: .urdu).contains(edition))
        #expect(RebuildError.referenceNotFound.message(language: .english)
            == "This reference was not found in the resource.")
    }
    @Test func aBackgroundLoaderCanResolveTheSavedLanguageWithoutOwningUIState() async throws {
        let name = "org.libronx.reader-error-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("pt", forKey: AppLanguage.defaultsKey)
        let value = await Task.detached {
            let defaults = UserDefaults(suiteName: name)!
            return RebuildError.referenceNotFound.message(language: AppLanguage.saved(in: defaults))
        }.value
        #expect(value == "Esta referência não foi encontrada no recurso.")
        defaults.set("unsupported", forKey: AppLanguage.defaultsKey)
        #expect(AppLanguage.saved(in: defaults) == .spanish)
    }
}
