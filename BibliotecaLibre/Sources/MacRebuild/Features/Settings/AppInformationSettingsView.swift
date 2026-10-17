import SwiftUI

struct AppInformationSettingsView: View {
    private let icons = AppIconPreferences.shared
    private var version: String { AppUpdater.shared.installedVersion }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    private var distribution: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "LibronXUpdateChannel") as? String ?? ""
        return UpdateChannel(rawValue: value)?.title ?? (version.contains("-") ? "Beta" : "Stable")
    }
    private var minimumSystem: String {
        "macOS " + (Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "14.0")
    }
    private var processor: String {
        #if arch(arm64)
        "Apple silicon"
        #elseif arch(x86_64)
        "Intel"
        #else
        "—"
        #endif
    }
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    if let image = icons.image(for: icons.selected) {
                        Image(nsImage: image).resizable().interpolation(.high).frame(width: 56, height: 56)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Libron-X").font(.title2.weight(.semibold))
                        Text(L("Biblioteca de estudio bíblico con lecturas en paralelo, búsqueda y documentos personales."))
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, 8)
                row("Versión instalada", value: version)
                row("Tipo de versión", value: distribution)
                row("Revisión interna", value: build)
                row("Desarrollador", value: "EstebanPdN")
                row("Licencia del código", value: "MIT")
            }
            if let root = BundledDictionaries.root,
               FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.json").path) {
                Section(L("Diccionarios incluidos")) {
                    row("Diccionarios", value: String((try? BundledDictionaries.resources(at: root).count) ?? 0))
                    row("Licencia", value: "CC BY-SA · CC BY · GPL · LGPL")
                    Link(L("Créditos y fuentes"), destination: root.appendingPathComponent("Packages"))
                    Link("Wiktionary · Kaikki.org", destination: URL(string: "https://kaikki.org/dictionary/rawdata.html")!)
                }
            }
            Section(L("Requisitos")) {
                row("macOS mínimo", value: minimumSystem)
                row("Procesador", value: processor)
            }
            Section {
                HStack {
                    Link(L("Ver proyecto en GitHub"), destination: URL(string: "https://github.com/EstebanPdNS/Libron-X")!)
                    Spacer()
                    Link(L("Reportar un problema"), destination: URL(string: "https://github.com/EstebanPdNS/Libron-X/issues/new")!)
                }.buttonStyle(.link)
            }
        }.formStyle(.grouped).featureHelpTarget(.information)
    }
    private func row(_ label: String, value: String) -> some View {
        HStack(alignment: .center) {
            Text(L(label))
            Spacer(minLength: 16)
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
