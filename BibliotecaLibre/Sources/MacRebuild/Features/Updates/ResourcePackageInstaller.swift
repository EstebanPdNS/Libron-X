import Foundation
import CryptoKit
import LibronixCore

enum ResourceDownloadEvent: Sendable {
    case collection(String, [ResourceCollectionEntry])
    case progress(String, Double, String)
    case finished(String, ResourceDownloadOutcome, String?)
}
enum ResourceDownloadOutcome: String, Sendable { case new, updated, installed, failed }
struct ResourceDownloadResult: Sendable {
    var new: [String] = []
    var updated: [String] = []
    var installed: [String] = []
    var failed: [String] = []
    var hiddenIDs: Set<String> = []
}
actor ResourcePackageInstaller {
    let root: URL
    let cache: URL
    let transport: any ResourceDownloadTransport
    init(root: URL, cache: URL, transport: any ResourceDownloadTransport = AnonymousResourceTransport()) {
        self.root = root.standardizedFileURL; self.cache = cache.standardizedFileURL; self.transport = transport
    }
    func install(_ code: ResourceDownloadCode, event: @escaping @Sendable (ResourceDownloadEvent) async -> Void) async throws -> ResourceDownloadResult {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? cache.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw LibronError.invalid("Invalid download destination") }
        let manifestFile = try await transport.fetch(code.url, maximumBytes: 64 * 1_024 * 1_024) { _ in }
        defer { try? fm.removeItem(at: manifestFile) }
        let manifest = try JSONDecoder().decode(ResourceCollectionManifest.self, from: code.open(Data(contentsOf: manifestFile)))
        try manifest.validate()
        await event(.collection(manifest.title, manifest.resources))
        var result = ResourceDownloadResult()
        var catalog = try existingResources()
        for entry in manifest.resources {
            try Task.checkCancellation()
            if entry.hidden { result.hiddenIDs.insert(entry.id) }
            do {
                let existing = catalog.first { $0.id == entry.id }?.packageLocation
                await event(.progress(entry.id, 0, "Comprobando archivos instalados…"))
                if let existing, try entry.matches(existing) {
                    result.installed.append(entry.title); await event(.finished(entry.id, .installed, nil)); continue
                }
                let target = try ResourceDownloadPaths.member(entry.packageName, under: root)
                if fm.fileExists(atPath: target.path), try LibronPackage.read(target).1.id != entry.id {
                    throw LibronError.invalid("Otro recurso utiliza el mismo nombre de archivo.")
                }
                let stage = root.appendingPathComponent(".download-" + UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: stage, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: stage) }
                let total = entry.files.reduce(Int64(0), { $0 + $1.downloadBytes })
                var completed: Int64 = 0
                for file in entry.files {
                    try Task.checkCancellation()
                    let previous = completed
                    let encrypted = try await object(file, manifest: manifest, code: code) { fraction in
                        Task { await event(.progress(entry.id, Double(previous) / Double(total) + fraction * Double(file.downloadBytes) / Double(total), "Descargando…")) }
                    }
                    let content = try code.open(Data(contentsOf: encrypted, options: .mappedIfSafe))
                    let plain = try ResourceDistributionCompression.inflate(content, expectedBytes: Int(file.bytes))
                    guard Self.hash(plain) == file.sha256 else { throw LibronError.invalid("El recurso descargado no coincide con su firma.") }
                    let output = try ResourceDownloadPaths.member(file.path, under: stage)
                    try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try plain.write(to: output, options: .atomic)
                    completed += file.downloadBytes
                }
                await event(.progress(entry.id, 1, "Verificando e instalando…"))
                guard try LibronPackage.read(stage, verify: true).1.id == entry.id else { throw LibronError.invalid("La identidad del recurso no coincide.") }
                try Task.checkCancellation()
                let backup = root.appendingPathComponent(".download-backup-" + UUID().uuidString, isDirectory: true)
                let old = existing ?? (fm.fileExists(atPath: target.path) ? target : nil)
                // Keep the previous package intact until the replacement and catalog commit.
                if let old { try fm.moveItem(at: old, to: backup) }
                do {
                    try fm.moveItem(at: stage, to: target)
                    let resource = try LibronPackage.read(target, verify: true).1
                    let fresh = try existingResources(excluding: entry.id) + [resource]
                    try LibronCatalog(resources: fresh).save(to: root)
                    catalog = fresh
                } catch {
                    try? fm.removeItem(at: target)
                    if let old { try? fm.moveItem(at: backup, to: old) }
                    throw error
                }
                if old != nil {
                    // Backups remain recoverable rather than deleting a user's prior edition.
                    let history = root.appendingPathComponent("backup/downloads", isDirectory: true)
                    try? fm.createDirectory(at: history, withIntermediateDirectories: true)
                    try? fm.moveItem(at: backup, to: history.appendingPathComponent(UUID().uuidString + ".libron"))
                    result.updated.append(entry.title)
                    await event(.finished(entry.id, .updated, nil))
                } else { result.new.append(entry.title); await event(.finished(entry.id, .new, nil)) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                result.failed.append(entry.title)
                await event(.finished(entry.id, .failed, error.localizedDescription))
            }
        }
        for font in manifest.readingFonts ?? [] {
            try Task.checkCancellation()
            let fonts = root.appendingPathComponent("Setup/Fonts", isDirectory: true)
            let target = try ResourceDownloadPaths.member("Setup/Fonts/" + font.path, under: root)
            if (try? LibronPackage.hash(target)) == font.sha256 { continue }
            let encrypted = try await object(font, manifest: manifest, code: code) { _ in }
            let plain = try ResourceDistributionCompression.inflate(code.open(Data(contentsOf: encrypted)), expectedBytes: Int(font.bytes))
            guard Self.hash(plain) == font.sha256 else { throw LibronError.invalid("Reading font checksum mismatch") }
            guard !fm.fileExists(atPath: target.path) else { throw LibronError.invalid("A different reading font already exists") }
            try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
            try plain.write(to: target, options: .atomic)
        }
        return result
    }
    private func existingResources(excluding excludedID: String? = nil) throws -> [LibraryResource] {
        let fm = FileManager.default
        let catalogURL = root.appendingPathComponent("catalog.json")
        var values = (fm.fileExists(atPath: catalogURL.path) ? try LibronCatalog.load(from: root).resources : []).filter { $0.id != excludedID }
        for package in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) where package.pathExtension == "libron" {
            if !values.contains(where: { $0.packageLocation?.resolvingSymlinksInPath().standardizedFileURL.path == package.resolvingSymlinksInPath().standardizedFileURL.path }) {
                let resource = try LibronPackage.read(package).1
                if resource.id != excludedID { values.append(resource) }
            }
        }
        guard Set(values.map(\.id)).count == values.count else { throw LibronError.invalid("La biblioteca contiene identificadores duplicados.") }
        return values
    }
    private func object(_ file: ResourceCollectionFile, manifest: ResourceCollectionManifest, code: ResourceDownloadCode,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let target = try ResourceDownloadPaths.member(file.encryptedSHA256 + ".lxblob", under: cache)
        if fm.fileExists(atPath: target.path) {
            if try validObject(target, file: file) { progress(1); return target }
            try fm.removeItem(at: target)
        }
        let url = try manifest.downloadURL(for: file, manifestURL: code.url)
        for attempt in 0..<3 {
            do {
                let downloaded = try await transport.fetch(url, maximumBytes: file.downloadBytes, progress: progress)
                defer { try? fm.removeItem(at: downloaded) }
                guard try validObject(downloaded, file: file) else { throw LibronError.invalid("La descarga está incompleta o dañada.") }
                try Task.checkCancellation()
                try fm.moveItem(at: downloaded, to: target)
                return target
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard attempt < 2, error is URLError else { throw error }
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw LibronError.invalid("Resource download did not finish")
    }
    private func validObject(_ url: URL, file: ResourceCollectionFile) throws -> Bool {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(file.downloadBytes) && LibronPackage.hash(url) == file.encryptedSHA256
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
