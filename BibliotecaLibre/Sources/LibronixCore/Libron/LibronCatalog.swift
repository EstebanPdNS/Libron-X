import Foundation

public struct LibronCatalog: Codable, Sendable {
    public var schemaVersion = 1
    public var resources: [LibraryResource]
    public init(resources: [LibraryResource]) { self.resources = resources }
    public static func load(from directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("catalog.json")
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 64 * 1024 * 1024 else { throw LibronError.invalid("Catalog exceeds limit") }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard catalog.schemaVersion == 1, Set(catalog.resources.map(\.id)).count == catalog.resources.count,
              catalog.resources.allSatisfy({ r in r.packageLocation?.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL }) else { throw LibronError.invalid("Invalid managed catalog") }
        return catalog
    }
    public func save(to directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        try encoder.encode(self).write(to: directory.appendingPathComponent("catalog.json"), options: .atomic)
    }
}
