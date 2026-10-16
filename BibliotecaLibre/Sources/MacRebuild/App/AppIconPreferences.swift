import AppKit
import Observation
import SwiftUI

enum AppIconVariant: String, CaseIterable, Identifiable {
    case red, black
    var id: String { rawValue }
    var title: String { self == .red ? "Rojo" : "Negro y rojo" }
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
        VStack(alignment: .leading, spacing: 20) {
            Text(L("Icono de la aplicación")).font(.title2.weight(.semibold))
            Text(L("Elige el icono de Libron X para el Dock.")).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                ForEach(AppIconVariant.allCases) { variant in
                    VStack(spacing: 10) {
                        if let image = preferences.image(for: variant) {
                            Image(nsImage: image).resizable().interpolation(.high).frame(width: 120, height: 120)
                        }
                        Button { preferences.select(variant) } label: {
                            Label(L(variant.title), systemImage: preferences.selected == variant ? "checkmark.circle.fill" : "circle")
                        }
                        .accessibilityLabel(L(variant.title))
                        .accessibilityValue(L(preferences.selected == variant ? "Seleccionado" : "Sin seleccionar"))
                    }.frame(maxWidth: .infinity)
                }
            }
            Text(preferences.message ?? L("Rojo es el icono predeterminado. Tu elección se guarda para la próxima apertura."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: 460)
    }
}
