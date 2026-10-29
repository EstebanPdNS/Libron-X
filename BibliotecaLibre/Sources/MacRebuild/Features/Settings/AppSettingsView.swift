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
                    HStack(alignment: .center) {
                        Text(L("Idioma de la interfaz"))
                        Spacer(minLength: 16)
                        MacSelectionMenu(L("Idioma de la interfaz"), value: preferences.language.nativeName, selection: $preferences.language) {
                            ForEach(AppLanguage.allCases) { language in Text(language.nativeName).tag(language) }
                        }.fixedSize().featureHelpTarget(.language)
                    }
                }
                Section(L("Al abrir Libron-X")) {
                    HStack(alignment: .center) {
                        Text(L("Abrir"))
                        Spacer(minLength: 16)
                        Picker(L("Abrir"), selection: $preferences.startup) {
                            ForEach(AppStartup.allCases) { mode in Text(L(mode.title)).tag(mode) }
                        }.labelsHidden().fixedSize().featureHelpTarget(.startup)
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
                    AppIconSettingsView().featureHelpTarget(.appearance)
                }
            }.formStyle(.grouped).featureHelpTarget(.appearance)
                .tabItem { Label(L("General"), systemImage: "gearshape") }
            Form {
                Section(L("Texto de los recursos")) {
                    HStack(alignment: .center) {
                        Text(L("Fuente")); Spacer(minLength: 16)
                        Picker(L("Fuente"), selection: $preferences.readingFont) {
                            Text(L("Predeterminada (Times New Roman)")).tag("")
                            ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { font in Text(font).tag(font) }
                        }.labelsHidden().frame(maxWidth: 300).featureHelpTarget(.reading)
                    }
                    HStack(alignment: .center) {
                        Text(L("Tamaño predeterminado"))
                        Spacer(minLength: 16)
                        Picker(L("Tamaño predeterminado"), selection: $preferences.readingScale) {
                            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3], id: \.self) { scale in
                                Text("\(Int(scale * 100)) %").tag(scale)
                            }
                        }.labelsHidden().fixedSize().featureHelpTarget(.reading)
                    }
                    Button(L("Aplicar a las lecturas abiertas")) {
                        for reader in workspace.readers { reader.textScale = preferences.readingScale }
                    }.disabled(workspace.readers.isEmpty)
                }
                Section(L("Notas y referencias")) {
                    HStack(alignment: .center) {
                        Text(L("Mostrar notas al mantener el puntero"))
                        Spacer(minLength: 16)
                        Toggle(L("Mostrar notas al mantener el puntero"), isOn: $preferences.hoverNotes)
                            .labelsHidden().toggleStyle(.switch).fixedSize()
                            .featureHelpTarget(.hoverNotes)
                    }
                }
            }.formStyle(.grouped).featureHelpTarget(.reading)
                .tabItem { Label(L("Lectura"), systemImage: "book") }
            LibrarySettingsView(workspace: workspace)
                .tabItem { Label(L("Biblioteca"), systemImage: "books.vertical") }
            ParallelBibleSettingsView(workspace: workspace)
                .tabItem { Label(L("Grupos"), systemImage: "rectangle.split.2x1") }
            UpdateSettingsView()
                .tabItem { Label(L("Actualizaciones"), systemImage: "arrow.down.circle") }
            AppInformationSettingsView()
                .tabItem { Label(L("Información"), systemImage: "info.circle") }
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
