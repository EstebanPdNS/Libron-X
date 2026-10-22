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
    @Bindable var workspace: StudyWorkspace
    @Bindable var updater = AppUpdater.shared
    @Bindable var downloads = ResourceDownloadController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(L("Descargas"), systemImage: "arrow.down.circle").font(.headline)
                Spacer()
                Button(L("Cerrar")) { updater.showsPanel = false }.keyboardShortcut(.cancelAction)
            }
            GroupBox(L("Actualizaciones de Libron-X")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(updater.installedVersion + " · " + updater.channel.title).foregroundStyle(.secondary)
                    UpdateStatusView(updater: updater)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox(L("Código de descarga")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField(L("Pega tu código de descarga"), text: $downloads.codeText).macInputStyle()
                            .accessibilityIdentifier("downloads.code").disabled(downloads.isBusy)
                            .onSubmit(start)
                        Button(L("Descargar recursos"), action: start)
                            .disabled(downloads.isBusy || downloads.codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !downloads.status.isEmpty {
                        HStack {
                            if downloads.isBusy { ProgressView().controlSize(.small) }
                            Text(L(downloads.status)).font(.callout)
                            Spacer()
                            if downloads.isBusy { Button(L("Cancelar")) { downloads.cancel() } }
                        }
                    }
                    if let error = downloads.error { Text(L(error)).foregroundStyle(.red).textSelection(.enabled) }
                    if !downloads.rows.isEmpty {
                        HStack {
                            Text(downloads.collectionTitle).font(.headline)
                            Spacer()
                            Text("\(downloads.finishedCount) / \(downloads.rows.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        List(downloads.rows) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(row.title).lineLimit(2)
                                    Spacer()
                                    if let outcome = row.outcome {
                                        Image(systemName: outcome == .failed ? "exclamationmark.circle" : "checkmark.circle.fill")
                                            .foregroundStyle(outcome == .failed ? Color.red : Color.green)
                                    }
                                }
                                Text(L(row.status)).font(.caption).foregroundStyle(.secondary)
                                if row.outcome == nil { ProgressView(value: row.progress) }
                                if let detail = row.detail { Text(L(detail)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                            }.padding(.vertical, 5)
                        }.listStyle(.inset).frame(minHeight: 190, maxHeight: 300)
                    }
                    if let result = downloads.result {
                        HStack(spacing: 16) {
                            Text(L("Nuevos") + ": \(result.new.count)")
                            Text(L("Actualizados") + ": \(result.updated.count)")
                            Text(L("Ya instalados") + ": \(result.installed.count)")
                            Text(L("Fallidos") + ": \(result.failed.count)")
                        }.font(.callout).textSelection(.enabled)
                    }
                }.padding(8)
            }
        }.padding(20).frame(width: 700).modifier(MacPanelControlPresentation())
    }
    private func start() {
        let root = workspace.libraryRoot ?? LibraryPreferences.shared.directory
        downloads.start(in: root) { hidden in workspace.reloadDownloadedResources(at: root, hiddenIDs: hidden) }
    }
}
