import Foundation
#if os(Windows)
import WinSDK
#endif

/// Synchronous, caller-owned resource traversal. Windows Foundation's URL
/// enumerator can return no entries for an accessible UNC share; path-based
/// shallow listing preserves the same resource URLs without that enumerator.
final class ResourceDirectoryEnumerator {
    #if os(Windows)
    private struct Frame {
        let directory: URL
        let names: [String]
        var index: Int = 0
    }
    private let manager = FileManager()
    private var frames: [Frame] = []
    private var pendingDirectory: URL?
    #else
    private let iterator: FileManager.DirectoryEnumerator
    #endif

    init?(root: URL, keys: [URLResourceKey]) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        #if os(Windows)
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return nil }
        frames = [Frame(directory: root, names: names)]
        #else
        guard let value = FileManager().enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        iterator = value
        #endif
    }

    func nextURL() throws -> URL? {
        #if os(Windows)
        if let directory = pendingDirectory {
            pendingDirectory = nil
            frames.append(Frame(directory: directory, names: try manager.contentsOfDirectory(atPath: directory.path)))
        }
        while !frames.isEmpty {
            try Task.checkCancellation()
            let index = frames.count - 1
            guard frames[index].index < frames[index].names.count else { frames.removeLast(); continue }
            let name = frames[index].names[frames[index].index]
            frames[index].index += 1
            guard !name.hasPrefix(".") else { continue }
            let url = frames[index].directory.appendingPathComponent(name)
            let path = url.path.replacingOccurrences(of: "/", with: "\\")
            let attributes = path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
            guard attributes != 0xffff_ffff else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            // Exclude directory junctions and symbolic links before descending.
            // They share the reparse-point flag; never traverse outside the
            // selected tree through one of these aliases.
            guard attributes & DWORD(FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_REPARSE_POINT) == 0 else { continue }
            if attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 {
                let values = try url.resourceValues(forKeys: [.isPackageKey])
                if values.isPackage != true { pendingDirectory = url }
            }
            return url
        }
        return nil
        #else
        while let value = iterator.nextObject() {
            if let url = value as? URL { return url }
        }
        return nil
        #endif
    }

    func skipDescendants() {
        #if os(Windows)
        pendingDirectory = nil
        #else
        iterator.skipDescendants()
        #endif
    }
}
