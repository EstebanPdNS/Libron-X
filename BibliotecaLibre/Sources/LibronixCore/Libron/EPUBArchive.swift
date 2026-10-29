import Foundation
import CLibronxCompression

/// Bounded ZIP reader: stored/DEFLATE, central-directory sizes and CRC checks.
/// No archive member is extracted to disk. ZIP64 and encrypted books fail explicitly.
public struct EPUBArchive: Sendable {
    public let source: URL
    public let metadata: LibronMetadata
    public let book: LibronixOEBBook
    public init(_ url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 22, size <= 256 * 1024 * 1024 else { throw LibronError.invalid("EPUB exceeds size limit") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func u16(_ at: Int) throws -> Int {
            guard at >= 0, at + 2 <= data.count else { throw LibronError.invalid("Invalid ZIP bounds") }
            return Int(data[at]) | Int(data[at + 1]) << 8
        }
        func u32(_ at: Int) throws -> Int { try u16(at) | u16(at + 2) << 16 }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try u32(offset) == 0x06054b50, try offset + 22 + u16(offset + 20) == data.count { end = offset; break }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0,
              try u16(end + 8) == u16(end + 10) else { throw LibronError.invalid("Unsupported multipart EPUB") }
        let count = try u16(end + 10), centralSize = try u32(end + 12), central = try u32(end + 16)
        guard count > 0, count < 20_000, central >= 0, central + centralSize == end else { throw LibronError.invalid("Unsupported EPUB ZIP directory") }
        var members: [String: Data] = [:], at = central, total = 0
        for _ in 0..<count {
            try Task.checkCancellation()
            guard try u32(at) == 0x02014b50 else { throw LibronError.invalid("Invalid EPUB ZIP entry") }
            let flags = try u16(at + 8), method = try u16(at + 10), crc = try u32(at + 16)
            let stored = try u32(at + 20), expanded = try u32(at + 24), nameCount = try u16(at + 28)
            let extra = try u16(at + 30), comment = try u16(at + 32), local = try u32(at + 42)
            guard flags & 1 == 0, [0,8].contains(method), expanded <= 16 * 1024 * 1024, stored <= 32 * 1024 * 1024,
                  nameCount > 0, at + 46 + nameCount + extra + comment <= end,
                  let name = String(data: data.subdata(in: at + 46 ..< at + 46 + nameCount), encoding: .utf8),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.split(separator: "/").contains("..") else { throw LibronError.invalid("Unsupported or unsafe EPUB member") }
            at += 46 + nameCount + extra + comment
            if name.hasSuffix("/") { continue }
            guard members[name] == nil, try u32(local) == 0x04034b50 else { throw LibronError.invalid("Duplicate EPUB member") }
            let start = try local + 30 + u16(local + 26) + u16(local + 28)
            guard start <= central, stored <= central - start else { throw LibronError.invalid("Invalid EPUB member extent") }
            total += expanded
            // Full-colour study Bibles can legitimately exceed 64 MiB after
            // decompression. Keep a bounded expansion while allowing them.
            guard total <= 128 * 1024 * 1024 else { throw LibronError.invalid("EPUB expansion exceeds limit") }
            let compressed = data.subdata(in: start ..< start + stored)
            var output: Data
            if method == 0 {
                guard stored == expanded else { throw LibronError.invalid("Invalid stored ZIP entry") }
                output = compressed
                let actual = output.withUnsafeBytes { libronx_crc32($0.bindMemory(to: UInt8.self).baseAddress, output.count) }
                guard actual == UInt32(crc) else { throw LibronError.invalid("EPUB checksum mismatch") }
            } else if expanded == 0 { output = Data() }
            else {
                output = Data(count: expanded)
                let status = compressed.withUnsafeBytes { input in output.withUnsafeMutableBytes { destination in
                    libronx_inflate_zip(input.bindMemory(to: UInt8.self).baseAddress, compressed.count, destination.bindMemory(to: UInt8.self).baseAddress, expanded, UInt32(crc))
                } }
                guard status == 0 else { throw LibronError.invalid("EPUB decompression/checksum failed") }
            }
            members[name] = output
        }
        guard members["mimetype"] == Data("application/epub+zip".utf8), members["META-INF/encryption.xml"] == nil,
              let container = members["META-INF/container.xml"] else { throw LibronError.invalid("Invalid or protected EPUB") }
        func descendants(_ node: XMLNode) -> [XMLNode] { [node] + node.children.flatMap(descendants) }
        let tree = try MetadataXMLReader.parse(container)
        guard let path = descendants(tree).first(where: { $0.name == "rootfile" })?.attributes["full-path"],
              let package = members[path] else { throw LibronError.invalid("EPUB package missing") }
        let opf = try MetadataXMLReader.parse(package), all = descendants(opf)
        let items = all.filter { $0.name == "item" }
        let base = (path as NSString).deletingLastPathComponent
        func resolve(_ href: String) throws -> String {
            guard let decoded = href.removingPercentEncoding, !decoded.contains(":"), !decoded.hasPrefix("/") else { throw LibronError.invalid("Unsafe EPUB spine path") }
            let resolved = URL(fileURLWithPath: "/epub-root/" + base, isDirectory: true).appendingPathComponent(decoded).standardizedFileURL.path
            guard resolved.hasPrefix("/epub-root/") else { throw LibronError.invalid("EPUB spine escapes container") }
            return String(resolved.dropFirst("/epub-root/".count))
        }
        var files: [String] = [], titles: [String] = []
        for item in all.filter({ $0.name == "itemref" && $0.attributes["linear"] != "no" }) {
            guard let id = item.attributes["idref"], let manifest = items.first(where: { $0.attributes["id"] == id }),
                  let href = manifest.attributes["href"], href.removingPercentEncoding != nil else { throw LibronError.invalid("EPUB spine missing") }
            let file = try resolve(href)
            guard members[file] != nil else { throw LibronError.invalid("EPUB spine member missing") }
            files.append(file); titles.append(id)
        }
        func field(_ name: String) -> String? { all.first { $0.name == "dc:" + name }?.text }
        var metadata = LibronMetadata(title: field("title") ?? url.deletingPathExtension().lastPathComponent, origin: "EPUB")
        metadata.authors = all.filter { $0.name == "dc:creator" }.map(\.text)
        metadata.languages = all.filter { $0.name == "dc:language" }.map(\.text)
        metadata.publisher = field("publisher"); metadata.year = field("date")
        self.source = url; self.metadata = metadata
        book = try LibronixOEBBook(source: url, directory: LibronixOEBDirectory(files: files, titles: titles), members: members)
    }
}
