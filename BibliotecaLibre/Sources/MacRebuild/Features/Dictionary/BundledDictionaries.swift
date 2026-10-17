import Foundation
import LibronixCore

@MainActor enum BundledDictionaries {
    static var root: URL? { Bundle.main.resourceURL?.appendingPathComponent("BundledDictionaries", isDirectory: true) }
    static func resources(at root: URL) throws -> [LibraryResource] {
        let packages = root.appendingPathComponent("Packages", isDirectory: true)
        let paths = try FileManager.default.contentsOfDirectory(at: packages, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.pathExtension == "libron" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard paths.count <= 64 else { throw LibronError.invalid("Bundled dictionary limit exceeded") }
        return try paths.map { try LibronPackage.read($0).1 }
    }
}
@MainActor extension StudyWorkspace {
    func includeBundledDictionaries() {
        guard let root = BundledDictionaries.root,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("Packages").path) else { return }
        do {
            let bundled = try BundledDictionaries.resources(at: root)
            let ids = Set(bundled.map(\.id))
            // Resolve saved references to the current installed application.
            resources = resources.filter { !ids.contains($0.id) } + bundled
        } catch { self.error = error.localizedDescription }
    }
}
