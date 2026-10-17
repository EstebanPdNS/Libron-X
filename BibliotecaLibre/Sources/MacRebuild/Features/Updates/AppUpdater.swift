import AppKit
import Observation

@MainActor @Observable final class AppUpdater {
    static let shared = AppUpdater()
    var channel: UpdateChannel {
        didSet {
            defaults.set(channel.rawValue, forKey: "updates.channel")
            generation += 1; task?.cancel(); task = nil; isBusy = false
            available = nil; prepared?.discard(); prepared = nil; defaults.removeObject(forKey: "updates.pending"); status = ""; lastChecked = nil
        }
    }
    var automaticChecks: Bool { didSet { defaults.set(automaticChecks, forKey: "updates.checks") } }
    var automaticInstall: Bool { didSet { defaults.set(automaticInstall, forKey: "updates.install") } }
    private(set) var isBusy = false
    private(set) var status = ""
    private(set) var available: GitHubRelease?
    private(set) var prepared: PreparedUpdate?
    private(set) var lastChecked: Date?
    var showsPanel = false
    var restartAfterInstall = false
    let installedVersion: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let service: GitHubUpdateService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var monitor: Task<Void, Never>?
    init(defaults: UserDefaults = .standard, service: GitHubUpdateService = GitHubUpdateService(), bundle: Bundle = .main) {
        self.defaults = defaults; self.service = service
        installedVersion = bundle.object(forInfoDictionaryKey: "LibronXReleaseVersion") as? String ??
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let bundledChannel = bundle.object(forInfoDictionaryKey: "LibronXUpdateChannel") as? String ?? "stable"
        channel = UpdateChannel(rawValue: defaults.string(forKey: "updates.channel") ?? bundledChannel) ?? .stable
        automaticChecks = defaults.object(forKey: "updates.checks") == nil ? true : defaults.bool(forKey: "updates.checks")
        automaticInstall = defaults.object(forKey: "updates.install") == nil ? true : defaults.bool(forKey: "updates.install")
        if let data = defaults.data(forKey: "updates.pending"), let pending = try? JSONDecoder().decode(PreparedUpdate.self, from: data) {
            if pending.installedApp == bundle.bundleURL, FileManager.default.fileExists(atPath: pending.stagedApp.path) {
                prepared = pending; status = "La actualización está lista para instalar."
            } else {
                let result = try? String(contentsOf: pending.workDirectory.appendingPathComponent("result.txt"), encoding: .utf8)
                if let result, result.trimmingCharacters(in: .whitespacesAndNewlines) != "installed" {
                    status = "No se pudo instalar la actualización. Se conservó la aplicación anterior."
                }
                defaults.removeObject(forKey: "updates.pending")
            }
        }
        if let error = defaults.string(forKey: "updates.lastInstallError") {
            status = error; defaults.removeObject(forKey: "updates.lastInstallError")
        }
    }
    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.automaticChecks { self.check(userInitiated: false) }
                do { try await Task.sleep(for: .seconds(21_600)) } catch { return }
            }
        }
    }
    func check(userInitiated: Bool = true) {
        if userInitiated { showsPanel = true }
        guard !isBusy, prepared == nil else { return }
        guard let installed = ReleaseVersion(installedVersion) else { status = "La versión instalada no es válida."; return }
        isBusy = true; status = "Buscando actualizaciones…"
        let selectedChannel = channel, token = generation
        task = Task {
            do {
                let releases = try await service.releases()
                try Task.checkCancellation()
                guard token == generation else { return }
                lastChecked = Date()
                available = GitHubRelease.newest(in: releases, channel: selectedChannel, installed: installed)
                isBusy = false
                if available != nil {
                    status = "Hay una actualización disponible."
                    if automaticInstall { download() }
                } else {
                    status = selectedChannel == .stable && !releases.contains(where: { !$0.draft && !$0.prerelease })
                        ? "Todavía no hay versiones Stable publicadas."
                        : "Libron-X está actualizado en este canal."
                }
            } catch {
                guard token == generation else { return }
                isBusy = false
                if !Task.isCancelled { status = error.localizedDescription }
            }
        }
    }
    func download() {
        guard !isBusy, let available else { return }
        isBusy = true; status = "Descargando y verificando la actualización…"
        let token = generation
        task = Task {
            do {
                let result = try await service.prepare(available, installedApp: Bundle.main.bundleURL)
                guard token == generation, !Task.isCancelled else { result.discard(); return }
                prepared = result; defaults.set(try JSONEncoder().encode(result), forKey: "updates.pending"); isBusy = false
                status = automaticInstall ? "La actualización se instalará al cerrar Libron-X." : "La actualización está lista para instalar."
            } catch {
                guard token == generation else { return }
                isBusy = false
                if !Task.isCancelled { status = error.localizedDescription }
            }
        }
    }
    func cancel() {
        generation += 1; task?.cancel(); task = nil; isBusy = false
        status = "Actualización cancelada."
    }
    func installAndRestart() {
        guard prepared != nil else { return }
        restartAfterInstall = true
        NSApplication.shared.terminate(nil)
        // terminate may be cancelled by workspace preservation; never leave a
        // restart intent behind for a later unrelated normal quit.
        restartAfterInstall = false
    }
    /// Called only after the normal workspace-save termination gate succeeds.
    func willTerminate() {
        task?.cancel(); monitor?.cancel()
        guard let prepared, automaticInstall || restartAfterInstall else { return }
        do {
            try prepared.launchAfterExit(pid: ProcessInfo.processInfo.processIdentifier, restart: restartAfterInstall)
        } catch {
            // Remain recoverable: no replacement has happened. Persist a visible
            // diagnostic for the next launch rather than silently claiming success.
            defaults.set(error.localizedDescription, forKey: "updates.lastInstallError")
        }
    }
}
