import Foundation
import SwiftUI

/// Interface languages are independent of the language and typography of a book.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    static let defaultsKey = "mac.interface.language.v1"
    case english = "en", spanish = "es", portuguese = "pt", french = "fr"
    case mandarin = "zh-Hans", hindi = "hi", arabic = "ar", bengali = "bn"
    case indonesian = "id", urdu = "ur"
    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .english: "English"
        case .mandarin: "简体中文"
        case .hindi: "हिन्दी"
        case .spanish: "Español"
        case .arabic: "العربية"
        case .french: "Français"
        case .bengali: "বাংলা"
        case .portuguese: "Português"
        case .indonesian: "Bahasa Indonesia"
        case .urdu: "اردو"
        }
    }
    var locale: Locale { Locale(identifier: rawValue) }
    var isRightToLeft: Bool { self == .arabic || self == .urdu }
    static func resolve(_ stored: String?) -> Self { stored.flatMap(Self.init(rawValue:)) ?? .spanish }
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        resolve(defaults.string(forKey: defaultsKey))
    }
}

enum AppStrings {
    static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "LibronX_MacRebuild", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
    /// The catalog is app-owned data, never a projection or translation of resource text.
    static let catalog: [String: [String: String]] = {
        guard let url = resourceBundle.url(forResource: "Interface", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return result
    }()
    static func text(_ key: String, language: AppLanguage) -> String {
        catalog[key]?[language.rawValue] ?? key
    }
    /// Named placeholders allow a translation to reorder values without printf types.
    /// Replacement walks the template once; inserted user/source text is never reprocessed.
    static func format(_ key: String, language: AppLanguage, values: [String: String]) -> String {
        let template = text(key, language: language)
        var result = "", cursor = template.startIndex
        while cursor < template.endIndex {
            if template[cursor] == "{", let end = template[cursor...].firstIndex(of: "}") {
                let name = String(template[template.index(after: cursor)..<end])
                if let value = values[name] {
                    result += value; cursor = template.index(after: end); continue
                }
            }
            result.append(template[cursor]); cursor = template.index(after: cursor)
        }
        return result
    }
}

@MainActor func L(_ key: String) -> String { AppStrings.text(key, language: AppPreferences.shared.language) }
@MainActor func LF(_ key: String, _ values: [String: String]) -> String {
    AppStrings.format(key, language: AppPreferences.shared.language, values: values)
}

/// Environment changes update controls in place, preserving reader identity,
/// selections, prefetched content and workspace geometry.
struct AppInterfaceLanguage: ViewModifier {
    private var preferences: AppPreferences { .shared }
    func body(content: Content) -> some View {
        content.environment(\.locale, preferences.language.locale)
            .environment(\.layoutDirection, preferences.language.isRightToLeft ? .rightToLeft : .leftToRight)
    }
}
