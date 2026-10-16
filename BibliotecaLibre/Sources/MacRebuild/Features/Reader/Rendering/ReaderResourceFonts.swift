import AppKit
import CoreText
import Darwin

/// Source-media fonts are registered only in this app process. Filesystem and
/// CoreText work run outside the UI actor. Basic POSIX metadata avoids Finder
/// extended-attribute queries, which can block on source-media directories.
actor ReaderResourceFonts {
    private static let shared = ReaderResourceFonts()
    private var registered: [URL: Int64] = [:]
    @discardableResult static func register(near resource: URL) async -> Int {
        await shared.load(near: resource)
    }
    private func load(near resource: URL) -> Int {
        let directory = resource.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Setup/Fonts", isDirectory: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return 0 }
        let modified = Int64(info.st_mtimespec.tv_sec)
        if registered[directory] == modified { return 0 }
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: directory.path), entries.count <= 256 else { return 0 }
        let fonts = entries.filter { ["ttf", "otf"].contains(($0 as NSString).pathExtension.lowercased()) }
        guard fonts.count <= 128 else { return 0 }
        var total: Int64 = 0, count = 0
        for name in fonts {
            if Task.isCancelled { return count }
            let url = directory.appendingPathComponent(name)
            var item = stat()
            guard lstat(url.path, &item) == 0, item.st_mode & S_IFMT == S_IFREG,
                  item.st_size > 0, item.st_size <= 16 * 1024 * 1024,
                  total <= 64 * 1024 * 1024 - item.st_size else { continue }
            total += item.st_size
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) { count += 1 }
        }
        registered[directory] = modified
        return count
    }
}
