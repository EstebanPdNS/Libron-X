import AppKit
import Observation
import SwiftUI

enum AppIconVariant: String, CaseIterable, Identifiable {
    case red, black
    var id: String { rawValue }
    var title: String { self == .red ? "Red" : "Dark" }
    var resourceName: String { self == .red ? "LibronX-Red" : "LibronX-Black" }
}

@MainActor @Observable final class AppIconPreferences {
    static let shared = AppIconPreferences()
    static let defaultsKey = "applicationIcon.approved02.variant.v1"
    private(set) var selected: AppIconVariant
    private(set) var message: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bundle: Bundle
    @ObservationIgnored private let applyImage: @MainActor (NSImage) -> Void
    @ObservationIgnored private var images: [AppIconVariant: NSImage] = [:]

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main,
         applyImage: @escaping @MainActor (NSImage) -> Void = { NSApplication.shared.applicationIconImage = $0 }) {
        self.defaults = defaults; self.bundle = bundle; self.applyImage = applyImage
        selected = AppIconVariant(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "") ?? .red
    }
    func image(for variant: AppIconVariant) -> NSImage? {
        if let image = images[variant] { return image }
        guard let url = bundle.url(forResource: variant.resourceName, withExtension: "icns"),
              let image = NSImage(contentsOf: url), image.isValid else { return nil }
        images[variant] = image
        return image
    }
    func applySavedSelection() {
        if let image = image(for: selected) { applyImage(image) }
    }
    func select(_ variant: AppIconVariant) {
        guard let image = image(for: variant) else {
            message = L("No se ha podido cargar este icono. Se conserva la elección anterior.")
            return
        }
        // Runtime choices change the Dock image, never the signed app bundle.
        // Finder receives the approved red default through CFBundleIconFile.
        applyImage(image)
        selected = variant; defaults.set(variant.rawValue, forKey: Self.defaultsKey)
        message = nil
    }
}

struct AppIconSettingsView: View {
    private let preferences: AppIconPreferences
    init(preferences: AppIconPreferences = .shared) { self.preferences = preferences }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Icono de la aplicación"))
                Spacer()
                ForEach(AppIconVariant.allCases) { variant in
                    Button { preferences.select(variant) } label: {
                        HStack(spacing: 6) {
                            if let image = preferences.image(for: variant) {
                                Image(nsImage: image).resizable().interpolation(.high).frame(width: 28, height: 28)
                            }
                            Text(verbatim: variant.title).font(.callout)
                            Image(systemName: "checkmark").font(.caption.weight(.semibold))
                                .opacity(preferences.selected == variant ? 1 : 0)
                        }
                    }.controlSize(.small)
                        .help(variant.title)
                        .accessibilityLabel(variant.title)
                        .accessibilityValue(L(preferences.selected == variant ? "Seleccionado" : "Sin seleccionar"))
                }
            }
            if let message = preferences.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
