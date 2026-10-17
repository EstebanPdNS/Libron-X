import Foundation

public struct LibronixOEBArticle: Codable, Sendable, Equatable {
    public let ordinal: Int
    public let sourceID: UInt32
    public let fileIndex: Int
    public let parent: Int?
    public let nextSibling: Int?
    public let depth: Int
    public let sourceHeadingLevel: Int
    public let title: String
    public let fragment: String
    public let path: String
}

/// Native OebResourceFileData.cpp and OebResourceArticleData.cpp, version 1.0.
/// File-table rows are in reading order; the third word is a separate name-sort
/// permutation. Article +4 indexes the physical row, not that permutation.
public struct LibronixOEBDirectory: Codable, Sendable {
    public let files: [String]
    public let nameOrder: [Int]
    public let articles: [LibronixOEBArticle]

    public init(files: [String], titles: [String]) throws {
        guard !files.isEmpty, files.count == titles.count, files.allSatisfy(Self.validPath) else { throw LibronixBookError.invalidDirectory }
        self.files = files; self.nameOrder = Array(files.indices)
        self.articles = files.enumerated().map { i, path in .init(ordinal: i, sourceID: UInt32(i), fileIndex: i, parent: nil,
            nextSibling: i + 1 < files.count ? i + 1 : nil, depth: 0, sourceHeadingLevel: 1, title: titles[i], fragment: "", path: path) }
    }
    public init(fileTable: Data, articleTable: Data) throws {
        func word(_ data: Data, _ offset: Int) throws -> Int {
            guard offset >= 0, offset <= data.count, 4 <= data.count - offset else { throw LibronixBookError.invalidDirectory }
            return (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        func header(_ data: Data, _ magic: String) throws {
            guard data.prefix(4) == Data(magic.utf8), try word(data, 4) == 0x0100_0000,
                  try word(data, 8) == 12 else { throw LibronixBookError.unsupportedArchive }
        }
        func string(_ data: Data, base: Int, end: Int, offset: Int, count: Int) throws -> String {
            guard base >= 0, end <= data.count, base <= end, offset >= 0, offset <= end - base,
                  count >= 2, count % 2 == 0, count <= end - base - offset else { throw LibronixBookError.invalidDirectory }
            let bytes = data.subdata(in: (base + offset)..<(base + offset + count))
            guard bytes.suffix(2) == Data([0, 0]),
                  let text = String(data: bytes.dropLast(2), encoding: .utf16LittleEndian),
                  !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw LibronixBookError.invalidDirectory }
            return text
        }
        try header(fileTable, "LOEF"); try header(articleTable, "LOEA")
        let fileCount = try word(fileTable, 12), filePool = try word(fileTable, 16)
        guard (1...20_000).contains(fileCount), filePool == 24 + fileCount * 12, filePool <= fileTable.count else { throw LibronixBookError.invalidDirectory }
        var names: [String] = [], permutation: [Int] = []
        for ordinal in 0..<fileCount {
            let at = 24 + ordinal * 12
            let name = try string(fileTable, base: filePool, end: fileTable.count,
                                  offset: word(fileTable, at), count: word(fileTable, at + 4))
            guard Self.validPath(name) else { throw LibronixBookError.invalidDirectory }
            names.append(name.replacingOccurrences(of: "\\", with: "/"))
            permutation.append(try word(fileTable, at + 8))
        }
        guard Set(names.map { $0.lowercased() }).count == names.count,
              Set(permutation) == Set(0..<fileCount) else { throw LibronixBookError.invalidDirectory }
        let count = try word(articleTable, 12), titles = try word(articleTable, 16), anchors = try word(articleTable, 20)
        guard (1...100_000).contains(count), titles == 32 + count * 36,
              anchors >= titles, anchors <= articleTable.count,
              try word(articleTable, 24) == 0, try word(articleTable, 28) == count - 1 else { throw LibronixBookError.invalidDirectory }
        var result: [LibronixOEBArticle] = []
        for ordinal in 0..<count {
            let at = 32 + ordinal * 36
            let file = try word(articleTable, at + 4), parent = try word(articleTable, at + 8)
            let sibling = try word(articleTable, at + 12), headingLevel = try word(articleTable, at + 16)
            guard names.indices.contains(file), parent == 0xffff_ffff || parent < ordinal,
                  sibling == 0xffff_ffff || (sibling > ordinal && sibling < count), headingLevel <= 64 else { throw LibronixBookError.invalidDirectory }
            let depth = parent == 0xffff_ffff ? 0 : result[parent].depth + 1
            guard depth <= 64 else { throw LibronixBookError.limitExceeded }
            result.append(try .init(ordinal: ordinal, sourceID: UInt32(word(articleTable, at)), fileIndex: file,
                parent: parent == 0xffff_ffff ? nil : parent, nextSibling: sibling == 0xffff_ffff ? nil : sibling, depth: depth, sourceHeadingLevel: headingLevel,
                title: string(articleTable, base: titles, end: anchors, offset: word(articleTable, at + 20), count: word(articleTable, at + 24)),
                fragment: string(articleTable, base: anchors, end: articleTable.count, offset: word(articleTable, at + 28), count: word(articleTable, at + 32)),
                path: names[file]))
        }
        files = names; nameOrder = permutation; articles = result
    }
    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains(":") && !path.hasPrefix("/") && !path.hasPrefix("\\") &&
        !path.unicodeScalars.contains(where: { $0.value < 32 }) &&
        path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// Original page/stylesheet/image bytes remain immutable. The generated origin
/// is process-local; persistent workspaces save article ordinals and fragments.
public struct LibronixOEBBook: Sendable {
    public let origin: String
    public let source: URL
    public let directory: LibronixOEBDirectory
    public let members: [String: Data]
    private let paths: [String: String]
    private let stamp: LegacyGraphicSourceStamp

    public init(source: URL, directory: LibronixOEBDirectory, members: [String: Data]) throws {
        let pairs = members.keys.map { ($0.lowercased(), $0) }
        guard Set(pairs.map(\.0)).count == pairs.count else { throw LibronixBookError.invalidDirectory }
        let paths = Dictionary(uniqueKeysWithValues: pairs)
        guard directory.files.allSatisfy({ paths[$0.lowercased()] != nil }) else { throw LibronixBookError.entryNotFound }
        self.source = source; self.directory = directory; self.members = members; self.paths = paths
        stamp = try LegacyGraphicsService.fileStamp(source); origin = UUID().uuidString.lowercased()
    }
    public func verifySource() throws {
        guard try LegacyGraphicsService.fileStamp(source) == stamp else { throw LibronixBookError.sourceChanged }
    }
    public func url(path: String, fragment: String? = nil) -> URL {
        var parts = URLComponents(); parts.scheme = "libronx-oeb"; parts.host = origin
        parts.path = "/" + path; parts.fragment = fragment?.isEmpty == false ? fragment : nil
        return parts.url!
    }
    public func path(for url: URL) -> String? {
        guard url.scheme == "libronx-oeb", url.host == origin, url.user == nil, url.password == nil,
              url.port == nil, url.query == nil else { return nil }
        let path = String(url.path.dropFirst())
        guard !path.contains("\\"), !path.components(separatedBy: "/").contains("..") else { return nil }
        return paths[path.lowercased()]
    }
    public func article(for url: URL) -> LibronixOEBArticle? {
        guard let path = path(for: url) else { return nil }
        let candidates = directory.articles.filter { $0.path.lowercased() == path.lowercased() }
        if let fragment = url.fragment?.removingPercentEncoding, !fragment.isEmpty,
           let exact = candidates.first(where: { $0.fragment == fragment }) { return exact }
        return candidates.first
    }
    public static func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm", "xhtml": "text/html"
        case "css": "text/css"
        case "bmp": "image/bmp"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "woff": "font/woff"
        default: "application/octet-stream"
        }
    }
}

public actor LibronixOEBService {
    public static let shared = LibronixOEBService()
    private var cache: [URL: LibronixOEBBook] = [:]
    private var order: [URL] = []
    public init() {}
    public func prepare(_ url: URL) throws -> LibronixOEBBook {
        if let book = cache[url] {
            do { try book.verifySource(); order.removeAll { $0 == url }; order.append(url); return book }
            catch { cache[url] = nil; order.removeAll { $0 == url } }
        }
        let stamp = try LegacyGraphicsService.fileStamp(url)
        let archive = try LibronixBookArchive.inspect(at: url)
        let members = try archive.readEntries(archive.entries.filter {
            $0.path == "_file_info.dat" || $0.path == "_article_info.dat" ||
            Self.renderableExtensions.contains(($0.path as NSString).pathExtension.lowercased())
        }.map(\.path))
        guard let files = members["_file_info.dat"], let articles = members["_article_info.dat"] else { throw LibronixBookError.missingText }
        let directory = try LibronixOEBDirectory(fileTable: files, articleTable: articles)
        let book = try LibronixOEBBook(source: url, directory: directory, members: members)
        guard try LegacyGraphicsService.fileStamp(url) == stamp else { throw LibronixBookError.sourceChanged }
        cache[url] = book; order.append(url)
        while order.count > 2 { cache[order.removeFirst()] = nil }
        return book
    }
    private static let renderableExtensions: Set<String> = ["html", "htm", "css", "bmp", "png", "jpg", "jpeg", "gif", "svg", "ttf", "otf", "woff"]
}
