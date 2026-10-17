import SwiftUI

struct UpdateSettingsView: View {
    @Bindable var updater = AppUpdater.shared
    @RebuildViewState private var showsReleaseNotes = false
    var body: some View {
        Form {
            Section(L("Actualizaciones")) {
                HStack(alignment: .center) {
                    Text(L("Versión instalada"))
                    Spacer()
                    Text(updater.installedVersion).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(alignment: .center) {
                    Text(L("Canal de actualizaciones"))
                    Spacer(minLength: 16)
                    Picker(L("Canal de actualizaciones"), selection: $updater.channel) {
                        ForEach(UpdateChannel.allCases) { channel in Text(channel.title).tag(channel) }
                    }.labelsHidden().fixedSize()
                }
                centeredToggle("Buscar actualizaciones automáticamente", isOn: $updater.automaticChecks)
                centeredToggle("Descargar e instalar automáticamente al cerrar", isOn: $updater.automaticInstall)
            }
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    UpdateStatusView(updater: updater)
                    Link(L("Ver versiones en GitHub"), destination: URL(string: "https://github.com/EstebanPdNS/Libron-X/releases")!)
                        .buttonStyle(.link)
                }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                DisclosureGroup(isExpanded: $showsReleaseNotes) {
                    InstalledReleaseNotesView(version: updater.installedVersion)
                        .padding(.top, 8)
                } label: {
                    Button { showsReleaseNotes.toggle() } label: {
                        Text(L("Cambios de esta versión")).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }.featureHelpTarget(.changelog)
            }
        }.formStyle(.grouped).featureHelpTarget(.updates)
    }
    private func centeredToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            Text(L(title)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            Toggle(L(title), isOn: isOn).labelsHidden().toggleStyle(.switch).fixedSize()
        }
    }
}
struct UpdateStatusView: View {
    @Bindable var updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                if updater.isBusy { ProgressView().controlSize(.small) }
                if !updater.status.isEmpty { Text(L(updater.status)).font(.callout).textSelection(.enabled) }
            }
            if let release = updater.available { Text(release.tag_name).font(.headline) }
            if let checked = updater.lastChecked {
                Text(L("Última comprobación") + ": " + checked.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(L("Buscar actualizaciones")) { updater.check(userInitiated: false) }.disabled(updater.isBusy || updater.prepared != nil)
                if updater.isBusy { Button(L("Cancelar")) { updater.cancel() } }
                if updater.prepared != nil {
                    Button(L("Instalar y reiniciar")) { updater.installAndRestart() }.keyboardShortcut(.defaultAction)
                } else if updater.available != nil && !updater.isBusy {
                    Button(L("Descargar actualización")) { updater.download() }
                }
            }
        }
    }
}
struct UpdatePanel: View {
    @Bindable var updater = AppUpdater.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(L("Actualizaciones de Libron-X"), systemImage: "arrow.down.circle").font(.headline)
                Spacer()
                Button(L("Listo")) { updater.showsPanel = false }.keyboardShortcut(.cancelAction)
            }
            Text(updater.installedVersion + " · " + updater.channel.title).foregroundStyle(.secondary)
            UpdateStatusView(updater: updater)
        }.padding(20).frame(width: 460).modifier(MacPanelControlPresentation())
    }
}
