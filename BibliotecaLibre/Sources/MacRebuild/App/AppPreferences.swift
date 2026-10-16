import AppKit
import Observation

/// Personal Mac preferences are separate from resource typography and original
/// library files. UI ownership stays on the main actor.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: "Automático"; case .light: "Claro"; case .dark: "Oscuro" } }
}
enum AppStartup: String, CaseIterable, Identifiable {
    case restorePrevious, blank, home, library, workspace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .restorePrevious: "Restaurar las lecturas anteriores"
        case .blank: "Ventana vacía"
        case .home: "Inicio"
        case .library: "Mi biblioteca"
        case .workspace: "Área de trabajo guardada"
        }
    }
}
@MainActor @Observable final class AppPreferences {
    static let shared = AppPreferences()
    static let appearanceKey = "mac.appearance.v1"
    static let readingScaleKey = "mac.readingDefaultScale.v1"
    static let hoverNotesKey = "mac.hoverNotePreviews.v1"
    static let startupKey = "mac.startup.mode.v1"
    static let startupWorkspaceKey = "mac.startup.workspace.v1"
    static let languageKey = AppLanguage.defaultsKey
    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.languageKey)
            // App-domain language override for standard AppKit panels and menus.
            // macOS caches those strings until the next application launch.
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
    var startup: AppStartup { didSet { defaults.set(startup.rawValue, forKey: Self.startupKey) } }
    var startupWorkspaceURL: URL? {
        didSet {
            guard startupWorkspaceURL?.isFileURL != false else { startupWorkspaceURL = oldValue; return }
            defaults.set(startupWorkspaceURL?.absoluteString, forKey: Self.startupWorkspaceKey)
        }
    }
    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey); applyAppearance(appearance) }
    }
    var readingScale: Double {
        didSet {
            guard readingScale.isFinite, (0.5...3).contains(readingScale) else { readingScale = oldValue; return }
            defaults.set(readingScale, forKey: Self.readingScaleKey)
        }
    }
    var hoverNotes: Bool { didSet { defaults.set(hoverNotes, forKey: Self.hoverNotesKey) } }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let applyAppearance: (AppAppearance) -> Void
    init(defaults: UserDefaults = .standard, applyAppearance: @escaping (AppAppearance) -> Void = { choice in
        NSApplication.shared.appearance = switch choice {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }) {
        self.defaults = defaults; self.applyAppearance = applyAppearance
        language = AppLanguage.resolve(defaults.string(forKey: Self.languageKey))
        startup = AppStartup(rawValue: defaults.string(forKey: Self.startupKey) ?? "") ?? .restorePrevious
        let workspaceURL = defaults.string(forKey: Self.startupWorkspaceKey).flatMap(URL.init(string:))
        startupWorkspaceURL = workspaceURL?.isFileURL == true ? workspaceURL : nil
        appearance = AppAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        let stored = defaults.double(forKey: Self.readingScaleKey)
        readingScale = stored.isFinite && (0.5...3).contains(stored) ? stored : 1
        hoverNotes = defaults.object(forKey: Self.hoverNotesKey) == nil ? true : defaults.bool(forKey: Self.hoverNotesKey)
    }
    func applySavedAppearance() { applyAppearance(appearance) }
}
