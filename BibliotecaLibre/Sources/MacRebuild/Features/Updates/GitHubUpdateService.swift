import Foundation
import CryptoKit

actor GitHubUpdateService {
    static let releasesURL = URL(string: "https://api.github.com/repos/EstebanPdNS/Libron-X/releases")!
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func releases() async throws -> [GitHubRelease] {
        var all: [GitHubRelease] = []
        for page in 1...10 {
            var request = URLRequest(url: URL(string: Self.releasesURL.absoluteString + "?per_page=100&page=\(page)")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Libron-X-Updater", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw AppUpdateError.message("No se pudieron consultar las versiones de GitHub. Comprueba la conexión y vuelve a intentarlo.")
            }
            let batch = try JSONDecoder().decode([GitHubRelease].self, from: data)
            all += batch
            if batch.count < 100 { return all }
        }
        return all
    }
    func prepare(_ release: GitHubRelease, installedApp: URL) async throws -> PreparedUpdate {
        guard let asset = release.appAsset, let expected = asset.sha256, (1...1_073_741_824).contains(asset.size) else {
            throw AppUpdateError.message("Esta versión no incluye un ZIP de Libron-X con SHA-256 verificable.")
        }
        let fm = FileManager.default
        guard installedApp.pathExtension == "app", fm.isWritableFile(atPath: installedApp.deletingLastPathComponent().path),
              !installedApp.path.hasPrefix("/Volumes/") else {
            throw AppUpdateError.message("Mueve Libron-X a una carpeta con permiso de escritura, como Aplicaciones, antes de actualizar.")
        }
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.libronx.mac.rebuild/Updates/\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var keep = false
        defer { if !keep { try? fm.removeItem(at: root) } }
        let (download, response) = try await session.download(from: asset.browser_download_url)
        defer { try? fm.removeItem(at: download) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppUpdateError.message("La descarga de la actualización falló.")
        }
        let size = try download.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == asset.size else { throw AppUpdateError.message("La descarga está incompleta.") }
        let file = try FileHandle(forReadingFrom: download); defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
            throw AppUpdateError.message("La verificación SHA-256 falló. Se conservó la aplicación actual.")
        }
        try Task.checkCancellation()
        let archive = root.appendingPathComponent("update.zip"); try fm.moveItem(at: download, to: archive)
        // Reject traversal entries before extracting even a digest-verified asset.
        let entries = try Self.run("/usr/bin/zipinfo", ["-1", archive.path])
        for entry in entries.split(separator: "\n") {
            guard !entry.hasPrefix("/"), !entry.split(separator: "/").contains(".."), !entry.contains("\\") else {
                throw AppUpdateError.message("El archivo de actualización contiene rutas no válidas.")
            }
        }
        let listing = try Self.run("/usr/bin/zipinfo", ["-l", archive.path])
        guard !listing.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else {
            throw AppUpdateError.message("El archivo de actualización contiene enlaces no permitidos.")
        }
        let expanded = root.appendingPathComponent("expanded")
        try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
        let candidate = expanded.appendingPathComponent("Libron-X.app")
        try Self.validate(candidate, release: release)
        // Put the staged bundle on the destination volume before attempting any replacement.
        let staged = installedApp.deletingLastPathComponent().appendingPathComponent(".Libron-X-update-\(UUID().uuidString).app")
        do {
            try Self.run("/usr/bin/ditto", [candidate.path, staged.path])
            try Self.validate(staged, release: release)
        } catch { try? fm.removeItem(at: staged); throw error }
        let prepared = PreparedUpdate(stagedApp: staged, installedApp: installedApp, workDirectory: root, tag: release.tag_name)
        do { try prepared.writeHelper() } catch { try? fm.removeItem(at: staged); throw error }
        keep = true
        return prepared
    }
    static func validate(_ app: URL, release: GitHubRelease) throws {
        let fm = FileManager.default
        let info = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: info)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "org.libronx.mac.rebuild",
              plist["CFBundleExecutable"] as? String == "LibronXRebuild",
              let version = (plist["LibronXReleaseVersion"] ?? plist["CFBundleShortVersionString"]) as? String,
              ReleaseVersion(version) == release.version else {
            throw AppUpdateError.message("El paquete no corresponde a la versión esperada de Libron-X.")
        }
        if let minimum = plist["LSMinimumSystemVersion"] as? String,
           let required = ReleaseVersion(minimum) {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            guard let current = ReleaseVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"), current >= required else {
                throw AppUpdateError.message("Esta actualización necesita una versión más reciente de macOS.")
            }
        }
        let base = app.resolvingSymlinksInPath().path + "/"
        if let iterator = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in iterator {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
                   !url.resolvingSymlinksInPath().path.hasPrefix(base) {
                    throw AppUpdateError.message("El paquete contiene un enlace externo no permitido.")
                }
            }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        try run("/usr/bin/lipo", [app.appendingPathComponent("Contents/MacOS/LibronXRebuild").path, "-verify_arch", arch])
    }
    @discardableResult static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppUpdateError.message("No se pudo validar o preparar la actualización (\(URL(fileURLWithPath: path).lastPathComponent)).") }
        return String(decoding: data, as: UTF8.self)
    }
}
