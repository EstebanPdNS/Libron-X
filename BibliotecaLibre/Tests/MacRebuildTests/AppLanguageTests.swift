import Foundation
import Testing
@testable import MacRebuild

struct AppLanguageTests {
    @Test func tenDistinctLanguagesIncludeRequestedLanguagesAndTwoRightToLeftInterfaces() {
        #expect(Set(AppLanguage.allCases.map(\.rawValue)) == ["en", "zh-Hans", "hi", "es", "ar", "fr", "bn", "pt", "id", "ur"])
        #expect(Set(AppLanguage.allCases.map(\.nativeName)).count == 10)
        #expect(AppLanguage.allCases.filter(\.isRightToLeft) == [.arabic, .urdu])
        #expect(AppLanguage.resolve(nil) == .spanish)
        #expect(AppLanguage.resolve("future-language") == .spanish)
    }

    @Test(arguments: AppLanguage.allCases)
    func everyCatalogEntryHasARealNonemptyTranslationAndMatchingPlaceholders(language: AppLanguage) throws {
        #expect(AppStrings.catalog.count >= 255)
        let placeholders = try NSRegularExpression(pattern: #"\{([A-Za-z]+)\}"#)
        func names(_ value: String) -> Set<String> {
            let string = value as NSString
            return Set(placeholders.matches(in: value, range: NSRange(location: 0, length: string.length))
                .map { string.substring(with: $0.range(at: 1)) })
        }
        for (key, values) in AppStrings.catalog {
            let translation = try #require(values[language.rawValue], "Missing \(key) in \(language)")
            #expect(!translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(names(translation) == names(key))
            #expect(Set(values.keys) == Set(AppLanguage.allCases.map(\.rawValue)))
        }
    }

    @Test func translatedNamedValuesCanReorderWithoutReprocessingOriginalText() {
        let source = "Ge 1:1 · {total} · أصل · বাংলা · 😀"
        let translated = AppStrings.format("{current} de {total}", language: .hindi,
            values: ["current": source, "total": "99"])
        #expect(translated == "99 में से " + source)
        #expect(AppStrings.text(source, language: .arabic) == source)
        #expect(AppStrings.format("{current} de {total}", language: .english,
            values: ["current": "1"]) == "1 of {total}")
    }

    @MainActor @Test func languagePersistsInTheAppDomainWithoutChangingAppearanceOrReadingDefaults() throws {
        let name = "org.libronx.language-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dark", forKey: AppPreferences.appearanceKey)
        defaults.set(1.5, forKey: AppPreferences.readingScaleKey)
        defaults.set("black", forKey: AppIconPreferences.defaultsKey)
        defaults.set("previous-workspace", forKey: "unrelated")
        let preferences = AppPreferences(defaults: defaults, applyAppearance: { _ in })
        #expect(preferences.language == .spanish)
        for language in AppLanguage.allCases {
            preferences.language = language
            let reopened = AppPreferences(defaults: defaults, applyAppearance: { _ in })
            #expect(reopened.language == language)
            #expect(defaults.stringArray(forKey: "AppleLanguages") == [language.rawValue])
            #expect(reopened.appearance == .dark && reopened.readingScale == 1.5)
            #expect(defaults.string(forKey: AppIconPreferences.defaultsKey) == "black")
            #expect(defaults.string(forKey: "unrelated") == "previous-workspace")
        }
        defaults.set("future", forKey: AppPreferences.languageKey)
        #expect(AppPreferences(defaults: defaults, applyAppearance: { _ in }).language == .spanish)
    }

    @Test func literalUITranslationKeysExistAndBookTitlesNeverEnterTheTranslationPipeline() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MacRebuild")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let expressions = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)"\)"#)
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8), string = source as NSString
            #expect(!source.contains("L(resource.title)"))
            #expect(!source.contains("L(reader.resource.title)"))
            for match in expressions.matches(in: source, range: NSRange(location: 0, length: string.length)) {
                let raw = string.substring(with: match.range(at: 1))
                let key = try JSONDecoder().decode(String.self, from: Data(("\"" + raw + "\"").utf8))
                #expect(AppStrings.catalog[key] != nil, "Untranslated key in \(url.lastPathComponent): \(key)")
                checked += 1
            }
        }
        #expect(checked > 200)
    }
}
