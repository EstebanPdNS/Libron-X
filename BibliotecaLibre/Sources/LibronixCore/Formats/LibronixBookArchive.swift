import Foundation

public enum LibronixBookError: Error, LocalizedError, Sendable, Equatable {
    case invalidEnvelope, unsupportedProfile, verificationFailed, unsupportedArchive, invalidDirectory, entryNotFound, limitExceeded, sourceChanged, missingText
    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope: "El contenedor de Libronix tiene una cabecera o longitud inválida."
        case .unsupportedProfile: "Esta versión del contenedor de Libronix todavía no tiene un lector validado."
        case .verificationFailed: "La comprobación del contenedor de Libronix no coincide."
        case .unsupportedArchive: "La estructura interior de este recurso de Libronix todavía no se interpreta."
        case .invalidDirectory: "El directorio del recurso de Libronix contiene rangos o nombres inválidos."
        case .entryNotFound: "No se encontró el archivo solicitado dentro del recurso."
        case .limitExceeded: "El recurso supera los límites de lectura del contenedor."
        case .sourceChanged: "El archivo del recurso cambió durante la lectura. Vuelve a abrirlo."
        case .missingText: "Este recurso no contiene un texto LSF y un índice LIX compatibles."
        }
    }
}

public struct LibronixBookEntry: Codable, Equatable, Sendable {
    public let path: String
    public let offset: UInt64
    public let length: UInt64
}

public struct LibronixBookMetadata: Sendable {
    public let title: String?
    public let author: String?
    public let languages: [String]
    public let identifier: String?
    public let xml: XMLNode
    public var interlinearLines: [LibronixInterlinearLineDefinition] {
        let metadata = xml.child(named: "metadata")
        let options = metadata?.child(named: "controls")?.children(named: "control")
            .flatMap { $0.children(named: "options").flatMap { $0.children(named: "option") } } ?? []
        let definitions = options.first { $0.attributes["name"] == "interlinear" }?.children(named: "line") ?? []
        let settings = xml.child(named: "gpj")?.child(named: "Interlinear")?.children(named: "line") ?? []
        return definitions.enumerated().map { index, line in
            let name = line.attributes["name"] ?? ""
            let labels = line.children(named: "label")
            let label = labels.first { $0.attributes["xml:lang"] == "es" }?.text ?? labels.first?.text ?? name
            return .init(ordinal: index, name: name, label: label,
                visibleByDefault: settings.first { $0.attributes["name"] == name }?.attributes["show"] != "no")
        }
    }
}

public struct LibronixInterlinearLineDefinition: Sendable, Codable, Equatable {
    public let ordinal: Int
    public let name: String
    public let label: String
    public let visibleByDefault: Bool
}

/// A read-only resource archive, separate from configuration packages. Native
/// LibronixFile.cpp composes LTES with its format label "Libronix File" before
/// opening LEFS. This label is a stream-format input, not a license credential.
/// Book content/edition structures are inspected independently after unwrapping.
public struct LibronixBookArchive: Sendable {
    public static let maximumBytes: UInt64 = 512 * 1024 * 1024
    public let source: URL
    public let entries: [LibronixBookEntry]
    public let profile: UInt32
    public let logicalLength: UInt64
    private let stamp: LegacyGraphicSourceStamp

    public static func inspect(at url: URL) throws -> Self {
        let before = try LegacyGraphicsService.fileStamp(url)
        let stream = try LibronixBookStream(url)
        let header = try stream.read(offset: 0, count: 32)
        guard header.prefix(4) == Data("LEFS".utf8), header.bookU32(4) == 0x0100_0000,
              header.bookU32(16) == 12, header.bookU32(28) == 20 else { throw LibronixBookError.unsupportedArchive }
        let metadataLength = header.bookU64(20)
        guard metadataLength <= 16 * 1024 * 1024, metadataLength <= stream.length,
              56 <= stream.length - metadataLength else { throw LibronixBookError.invalidDirectory }
        let root = 32 + metadataLength
        let rootHeader = try stream.read(offset: root, count: 24)
        let dataStart = rootHeader.bookU64(0), slots = UInt64(rootHeader.bookU32(16))
        guard rootHeader.bookU32(12) == 16, (1...2048).contains(slots),
              dataStart >= root + 24, dataStart <= stream.length else { throw LibronixBookError.invalidDirectory }
        let recordWidth = 16 + slots * 2
        var entries: [LibronixBookEntry] = [], directories: [(UInt64, UInt64)] = []
        var visited = Set<UInt64>(), paths = Set<String>(), total = 0
        func visit(_ offset: UInt64, prefix: String, depth: Int, isRoot: Bool) throws {
            try Task.checkCancellation()
            let headerSize: UInt64 = isRoot ? 24 : 4
            guard depth <= 32, visited.insert(offset).inserted, offset >= root,
                  offset <= dataStart, headerSize <= dataStart - offset else { throw LibronixBookError.invalidDirectory }
            let count = Int(try stream.read(offset: offset + (isRoot ? 20 : 0), count: 4).bookU32(0))
            guard count <= 20_000, total <= 20_000 - count,
                  UInt64(count) <= (dataStart - offset - headerSize) / recordWidth else { throw LibronixBookError.limitExceeded }
            total += count
            let end = offset + headerSize + UInt64(count) * recordWidth
            directories.append((offset, end))
            let records = try stream.read(offset: offset + headerSize, count: Int(UInt64(count) * recordWidth))
            for index in 0..<count {
                let at = index * Int(recordWidth), start = records.bookU64(at), length = records.bookU64(at + 8)
                let raw = records.subdata(in: (at + 16)..<(at + Int(recordWidth)))
                let units = stride(from: 0, to: raw.count, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }
                guard let nul = units.firstIndex(of: 0),
                      let name = String(data: raw.prefix(nul * 2), encoding: .utf16LittleEndian),
                      !name.isEmpty, ![".", ".."].contains(name), !name.contains("/"), !name.contains("\\"),
                      !name.unicodeScalars.contains(where: { $0.value < 32 }),
                      start <= stream.length, length <= stream.length - start else { throw LibronixBookError.invalidDirectory }
                let path = prefix + name
                guard paths.insert(path).inserted else { throw LibronixBookError.invalidDirectory }
                if start < dataStart {
                    guard length == 0 else { throw LibronixBookError.invalidDirectory }
                    try visit(start, prefix: path + "/", depth: depth + 1, isRoot: false)
                } else { entries.append(.init(path: path, offset: start, length: length)) }
            }
        }
        try visit(root, prefix: "", depth: 0, isRoot: true)
        directories.sort { $0.0 < $1.0 }
        guard directories.first?.0 == root, directories.last?.1 == dataStart,
              zip(directories, directories.dropFirst()).allSatisfy({ $0.1 == $1.0 }) else { throw LibronixBookError.invalidDirectory }
        let extents = entries.filter { $0.length > 0 }.sorted { $0.offset < $1.offset }
        guard zip(extents, extents.dropFirst()).allSatisfy({ $0.offset + $0.length <= $1.offset }) else { throw LibronixBookError.invalidDirectory }
        guard try LegacyGraphicsService.fileStamp(url) == before else { throw LibronixBookError.sourceChanged }
        return Self(source: url, entries: entries, profile: stream.profile, logicalLength: stream.length, stamp: before)
    }

    public func readEntry(_ path: String, maximumBytes: Int = 16 * 1024 * 1024) throws -> Data {
        guard let entry = entries.first(where: { $0.path == path }) else { throw LibronixBookError.entryNotFound }
        guard maximumBytes >= 0, entry.length <= UInt64(maximumBytes) else { throw LibronixBookError.limitExceeded }
        try checkSource()
        let data = try LibronixBookStream(source).read(offset: entry.offset, count: Int(entry.length))
        try checkSource(); return data
    }

    /// Reads a bounded selection through one stream, avoiding repeated LZCS
    /// decompression for an OEB page and its original styles and images.
    public func readEntries(_ paths: [String], maximumTotalBytes: Int = 64 * 1024 * 1024) throws -> [String: Data] {
        guard maximumTotalBytes >= 0, Set(paths).count == paths.count else { throw LibronixBookError.invalidDirectory }
        let directory = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        var selected: [LibronixBookEntry] = [], total: UInt64 = 0
        for path in paths {
            guard let entry = directory[path] else { throw LibronixBookError.entryNotFound }
            guard entry.length <= 16 * 1024 * 1024, entry.length <= UInt64(maximumTotalBytes) - total else { throw LibronixBookError.limitExceeded }
            total += entry.length; selected.append(entry)
        }
        try checkSource()
        let stream = try LibronixBookStream(source)
        var result: [String: Data] = [:]
        for entry in selected {
            try Task.checkCancellation()
            result[entry.path] = try stream.read(offset: entry.offset, count: Int(entry.length))
        }
        try checkSource(); return result
    }

    /// Materializes only an explicitly requested member into a caller-owned
    /// cache. A failed or cancelled write removes its temporary file.
    public func copyEntry(_ path: String, to destination: URL) throws {
        guard let entry = entries.first(where: { $0.path == path }) else { throw LibronixBookError.entryNotFound }
        guard destination.standardizedFileURL != source.standardizedFileURL else { throw LibronixBookError.invalidDirectory }
        try checkSource()
        let stream = try LibronixBookStream(source), manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".libronx-" + UUID().uuidString)
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? manager.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        do {
            var written: UInt64 = 0
            while written < entry.length {
                try Task.checkCancellation()
                let count = Int(min(1_048_576, entry.length - written))
                try output.write(contentsOf: stream.read(offset: entry.offset + written, count: count)); written += UInt64(count)
            }
            try output.close(); try checkSource()
            if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: temporary) }
            else { try manager.moveItem(at: temporary, to: destination) }
        } catch { try? output.close(); throw error }
    }

    public func metadata() throws -> LibronixBookMetadata {
        let xml = try MetadataXMLReader.parse(readEntry("this.metadata.xml"))
        guard xml.name == "lbx-resource" else { throw LibronixBookError.unsupportedArchive }
        let metadata = xml.child(named: "metadata")
        let fields = metadata?.child(named: "dc-metadata")?.children.filter { $0.name == "dc-element" } ?? []
        let title = fields.first { $0.attributes["name"] == "dc.title" }?.text.components(separatedBy: "|").first
            ?? xml.child(named: "header")?.child(named: "title")?.text
        let author = fields.first { $0.attributes["name"]?.hasPrefix("dc.creator") == true }?.text
        let languages = fields.filter { $0.attributes["name"]?.hasPrefix("dc.language") == true }.map(\.text)
        return .init(title: title, author: author, languages: languages,
                     identifier: xml.attributes["guid"], xml: xml)
    }

    private func checkSource() throws {
        guard try LegacyGraphicsService.fileStamp(source) == stamp else { throw LibronixBookError.sourceChanged }
    }
}

private final class LibronixBookStream {
    let profile: UInt32
    private(set) var length: UInt64
    private let file: FileHandle
    private let base: UInt64
    private var decompressed: Data?
    private static let context: [UInt32] = {
        var words = [UInt32](repeating: 0, count: 4)
        for (index, byte) in "Libronix File".utf8.enumerated() { words[index & 3] = words[index & 3] &* 17 &+ UInt32(byte) }
        return words
    }()
    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        do {
            let size = try file.seekToEnd(); try file.seek(toOffset: 0)
            guard let header = try file.read(upToCount: 24), header.count >= 16,
                  header.prefix(4) == Data("LTES".utf8) else { throw LibronixBookError.invalidEnvelope }
            profile = header.bookU32(4); length = header.bookU64(8)
            guard profile == 0x0100_0000 || profile == 0x0101_0000 else { throw LibronixBookError.unsupportedProfile }
            base = profile == 0x0101_0000 ? 24 : 16
            guard size >= base, length <= LibronixBookArchive.maximumBytes,
                  length <= size - base, size - base - length <= 7, (size - base) % 8 == 0 else { throw LibronixBookError.invalidEnvelope }
            if profile == 0x0101_0000 {
                guard header.count == 24, Self.decode(header.subdata(in: 16..<24)) == header.prefix(8) else { throw LibronixBookError.verificationFailed }
            }
            if try read(offset: 0, count: Int(min(4, length))) == Data("LZCS".utf8) {
                guard length <= UInt64(LTESContainerReader.maximumContainerBytes) else { throw LibronixBookError.limitExceeded }
                var packed = Data(), offset: UInt64 = 0
                while offset < length {
                    let count = Int(min(1_048_576, length - offset))
                    packed.append(try read(offset: offset, count: count)); offset += UInt64(count)
                }
                let archive = try LTESContainerReader.decodeLZCS(packed).0
                decompressed = archive; length = UInt64(archive.count)
            }
        } catch { try? file.close(); throw error }
    }
    deinit { try? file.close() }
    func read(offset: UInt64, count: Int) throws -> Data {
        try Task.checkCancellation()
        guard count >= 0, count <= 16 * 1024 * 1024, offset <= length, UInt64(count) <= length - offset else { throw LibronixBookError.limitExceeded }
        if count == 0 { return Data() }
        if let decompressed { return decompressed.subdata(in: Int(offset)..<(Int(offset) + count)) }
        let aligned = offset / 8 * 8, lead = Int(offset - aligned), stored = (lead + count + 7) / 8 * 8
        try file.seek(toOffset: base + aligned)
        guard let bytes = try file.read(upToCount: stored), bytes.count == stored else { throw LibronixBookError.invalidEnvelope }
        return Self.decode(bytes).subdata(in: lead..<(lead + count))
    }
    private static func decode(_ input: Data) -> Data {
        var output = Data(count: input.count)
        output.withUnsafeMutableBytes { destination in
            let out = destination.bindMemory(to: UInt8.self)
            input.withUnsafeBytes { source in
                let bytes = source.bindMemory(to: UInt8.self)
                for start in stride(from: 0, to: bytes.count, by: 8) {
                    var a: UInt32 = 0, b: UInt32 = 0
                    for i in 0..<4 { a |= UInt32(bytes[start + i]) << (i * 8); b |= UInt32(bytes[start + 4 + i]) << (i * 8) }
                    var sum = UInt32(8) &* 0x9e37_79b9
                    for _ in 0..<8 {
                        b = b &- ((((a << 4) ^ (a >> 5)) &+ a) ^ (sum &+ context[Int((sum >> 11) & 3)]))
                        sum = sum &- 0x9e37_79b9
                        a = a &- ((((b << 4) ^ (b >> 5)) &+ b) ^ (sum &+ context[Int(sum & 3)]))
                    }
                    for i in 0..<4 { out[start + i] = UInt8(truncatingIfNeeded: a >> (i * 8)); out[start + 4 + i] = UInt8(truncatingIfNeeded: b >> (i * 8)) }
                }
            }
        }
        return output
    }
}

private extension Data {
    func bookU32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(self[at + $1]) << ($1 * 8) } }
    func bookU64(_ at: Int) -> UInt64 { UInt64(bookU32(at)) | UInt64(bookU32(at + 4)) << 32 }
}
