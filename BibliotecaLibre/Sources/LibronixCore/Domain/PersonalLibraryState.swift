import Foundation

/// Physical destinations belong to one edition. Original AOL strings stay
/// opaque until their coordinate contract has been independently established.
public struct ReaderLocation: Codable, Equatable, Sendable {
    public var resourceID: String
    public var legacyIdentifier: String?
    public var format: ResourceFormat
    public var sectionOrdinal: Int
    public var reference: String?
    public var textFingerprint: String?
    public var characterOffset: Int?

    public init(resourceID: String, legacyIdentifier: String? = nil, format: ResourceFormat,
                sectionOrdinal: Int, reference: String? = nil, textFingerprint: String? = nil, characterOffset: Int? = nil) {
        self.resourceID = resourceID; self.legacyIdentifier = legacyIdentifier; self.format = format
        self.sectionOrdinal = sectionOrdinal; self.reference = reference; self.textFingerprint = textFingerprint
        self.characterOffset = characterOffset
    }

    public func resolve(in resources: [LibraryResource]) -> LibraryResource? {
        // A fallback by identifier alone could pick a different edition/format.
        resources.first { $0.id == resourceID && $0.format == format && $0.legacyIdentifier == legacyIdentifier }
    }
}

public enum ReaderLinkGroup: String, Codable, CaseIterable, Sendable {
    case none, a = "A", b = "B", c = "C", d = "D", e = "E", f = "F"
    public var title: String { self == .none ? "Sin vínculo" : "Grupo \(rawValue)" }
}

public enum PersonalStateError: Error, LocalizedError {
    case invalid(String), futureVersion, concurrentChange, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        case .futureVersion: "Este archivo pertenece a una versión de Libron-X que todavía no se puede abrir."
        case .concurrentChange: "El archivo cambió desde que se abrió. Vuelve a abrirlo antes de guardar tus cambios."
        case .tooLarge: "El archivo supera el límite de 16 MB."
        }
    }
}

public enum FavoriteKind: String, Codable, Sendable { case folder, location, legacyCommand }

public struct LibraryFavorite: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var parentID: UUID?
    public var title: String
    public var kind: FavoriteKind
    public var location: ReaderLocation?
    public var legacyCommand: String?
    public init(id: UUID = UUID(), parentID: UUID? = nil, title: String, kind: FavoriteKind,
                location: ReaderLocation? = nil, legacyCommand: String? = nil) {
        self.id = id; self.parentID = parentID; self.title = title; self.kind = kind
        self.location = location; self.legacyCommand = legacyCommand
    }
}

public struct FavoritesDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var items: [LibraryFavorite] = []
    public init() {}
    public func children(of parentID: UUID?) -> [LibraryFavorite] { items.filter { $0.parentID == parentID } }
    public func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard items.count <= 10_000, Set(items.map(\.id)).count == items.count else {
            throw PersonalStateError.invalid("La lista de favoritos tiene demasiadas entradas o identificadores repetidos.")
        }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in items {
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.title.utf8.count <= 4_096 else { throw PersonalStateError.invalid("Escribe un título válido para el favorito.") }
            switch item.kind {
            case .folder:
                guard item.location == nil, item.legacyCommand == nil else { throw PersonalStateError.invalid("La carpeta contiene un destino incompatible.") }
            case .location:
                guard let location = item.location, location.sectionOrdinal >= 0,
                      location.characterOffset.map({ $0 >= 0 }) ?? true, item.legacyCommand == nil else { throw PersonalStateError.invalid("El favorito no tiene un destino válido.") }
            case .legacyCommand:
                guard item.location == nil, item.legacyCommand != nil else { throw PersonalStateError.invalid("El favorito importado no conserva su comando original.") }
            }
            var cursor = item.parentID, visited: Set<UUID> = [item.id]
            while let parent = cursor {
                guard visited.insert(parent).inserted, visited.count <= 128,
                      let folder = byID[parent], folder.kind == .folder else {
                    throw PersonalStateError.invalid("La jerarquía contiene una carpeta ausente, un ciclo o demasiados niveles.")
                }
                cursor = folder.parentID
            }
        }
    }
    public mutating func insert(_ favorite: LibraryFavorite) throws {
        var next = self; next.items.append(favorite); try next.validate(); self = next
    }
    public mutating func rename(_ id: UUID, title: String) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw PersonalStateError.invalid("El favorito ya no está disponible.") }
        var next = self; next.items[index].title = title; try next.validate(); self = next
    }
    public mutating func move(_ id: UUID, into parent: UUID?) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw PersonalStateError.invalid("El favorito ya no está disponible.") }
        var next = self; next.items[index].parentID = parent; try next.validate(); self = next
    }
    public mutating func remove(_ id: UUID) {
        var removed: Set<UUID> = [id]
        while true {
            let previous = removed.count
            for item in items where item.parentID.map(removed.contains) == true { removed.insert(item.id) }
            if removed.count == previous { break }
        }
        items.removeAll { removed.contains($0.id) }
    }
    public static func importingLegacyXML(_ data: Data) throws -> FavoritesDocument {
        let root = try MetadataXMLReader.parse(data)
        guard root.name == "favorites-collection" else { throw MetadataReadError.unsupportedDocument(root.name) }
        var result = FavoritesDocument()
        func visit(_ node: XMLNode, parent: UUID?) throws {
            for child in node.children {
                if child.name == "favorites-collection" {
                    let item = LibraryFavorite(parentID: parent, title: child.child(named: "title")?.text ?? "", kind: .folder)
                    try result.insert(item); try visit(child, parent: item.id)
                } else if child.name == "favorite" {
                    let item = LibraryFavorite(parentID: parent, title: child.child(named: "title")?.text ?? "", kind: .legacyCommand,
                        legacyCommand: child.attributes["command"])
                    try result.insert(item)
                }
            }
        }
        try visit(root, parent: nil); return result
    }
}

public struct NumberedBookmarks: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public private(set) var slots: [Int: ReaderLocation] = [:]
    public init() {}
    public mutating func set(_ slot: Int, location: ReaderLocation?) throws {
        guard (1...9).contains(slot), location.map({ $0.sectionOrdinal >= 0 && ($0.characterOffset.map({ $0 >= 0 }) ?? true) }) ?? true else { throw PersonalStateError.invalid("El marcador necesita un número del 1 al 9 y un destino válido.") }
        slots[slot] = location
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard slots.keys.allSatisfy({ (1...9).contains($0) }), slots.values.allSatisfy({ $0.sectionOrdinal >= 0 }) else { throw PersonalStateError.invalid("El archivo de marcadores no es válido.") }
    }
    public mutating func clear() { slots.removeAll() }
}

/// Saves are atomic and compare the file previously read. A successful save
/// also retains its predecessor, so a later interrupted write is recoverable.
public final class PersonalStateFile<Value: Codable> {
    public let url: URL
    private var previousBytes: Data?
    private var loaded = false
    public init(url: URL) { self.url = url }
    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { previousBytes = nil; loaded = true; return nil }
        let data = try readBounded(url)
        let value = try JSONDecoder().decode(Value.self, from: data)
        previousBytes = data; loaded = true; return value
    }
    public func save(_ value: Value) throws {
        guard loaded else { throw PersonalStateError.invalid("Abre el archivo antes de guardarlo.") }
        let current = FileManager.default.fileExists(atPath: url.path) ? try readBounded(url) : nil
        guard current == previousBytes else { throw PersonalStateError.concurrentChange }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let current { try current.write(to: url.appendingPathExtension("previous"), options: .atomic) }
        try data.write(to: url, options: .atomic)
        previousBytes = data
    }
    private func readBounded(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
        return data
    }
}
