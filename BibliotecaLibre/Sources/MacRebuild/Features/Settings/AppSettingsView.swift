import SwiftUI
import AppKit
import LibronixCore
import UniformTypeIdentifiers

struct AppSettingsView: View {
    let workspace: StudyWorkspace
    @Bindable private var preferences = AppPreferences.shared
    @RebuildViewState private var startupError: String?
    var body: some View {
        TabView {
            Form {
                Section {
                    Picker(L("Idioma de la interfaz"), selection: $preferences.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    Text(L("El idioma cambia la interfaz. Los libros conservan su texto original."))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(L("Los menús del sistema adoptan el idioma al volver a abrir la aplicación."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section(L("Al abrir Libron-X")) {
                    Picker(L("Abrir"), selection: $preferences.startup) {
                        ForEach(AppStartup.allCases) { mode in Text(L(mode.title)).tag(mode) }
                    }
                    if preferences.startup == .workspace {
                        HStack {
                            Text(preferences.startupWorkspaceURL?.lastPathComponent ?? L("Ningún área seleccionada"))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(L("Elegir…"), action: chooseStartupWorkspace)
                        }
                    }
                    if let startupError { Text(startupError).foregroundStyle(.red).font(.callout) }
                }
                Section(L("Apariencia")) {
                    Picker(L("Aspecto"), selection: $preferences.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in Text(L(appearance.title)).tag(appearance) }
                    }.pickerStyle(.radioGroup)
                    Text(L("Automático sigue la apariencia de macOS.")).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
                .tabItem { Label(L("General"), systemImage: "gearshape") }
            Form {
                Section(L("Texto de los recursos")) {
                    Picker(L("Tamaño predeterminado"), selection: $preferences.readingScale) {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3], id: \.self) { scale in
                            Text("\(Int(scale * 100)) %").tag(scale)
                        }
                    }
                    Text(L("Se aplica a las nuevas lecturas. El 100 % conserva el tamaño de lectura ampliado; los estilos del archivo original no se modifican."))
                        .font(.callout).foregroundStyle(.secondary)
                    Button(L("Aplicar a las lecturas abiertas")) {
                        for reader in workspace.readers { reader.textScale = preferences.readingScale }
                    }.disabled(workspace.readers.isEmpty)
                }
                Section(L("Notas y referencias")) {
                    Toggle(L("Mostrar notas al mantener el puntero"), isOn: $preferences.hoverNotes)
                    Text(L("También puedes abrirlas haciendo clic en su llamada.")).font(.callout).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
                .tabItem { Label(L("Lectura"), systemImage: "book") }
            ParallelBibleSettingsView(workspace: workspace)
                .tabItem { Label(L("Paralelos"), systemImage: "books.vertical") }
            AppIconSettingsView()
                .tabItem { Label(L("Icono"), systemImage: "app") }
            LibrarySettingsView(workspace: workspace)
                .tabItem { Label(L("Biblioteca"), systemImage: "books.vertical") }
        }.frame(width: 700, height: 580).modifier(MacPanelControlPresentation())
    }
    private func chooseStartupWorkspace() {
        let panel = NSOpenPanel(); panel.title = L("Área de trabajo guardada")
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let file = PersonalStateFile<WorkspaceArchive>(url: url)
                guard let archive = try file.load() else { throw PersonalStateError.invalid("No se pudo leer el área de trabajo.") }
                try archive.validate(); preferences.startupWorkspaceURL = url; startupError = nil
            } catch { startupError = error.localizedDescription }
        }
    }

}
