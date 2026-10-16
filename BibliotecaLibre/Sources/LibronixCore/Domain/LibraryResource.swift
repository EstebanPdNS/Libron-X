import Foundation

/// The physical format detected at the import boundary. Format is independent
/// from permission to use a work and from whether its content decoder exists.
public enum ResourceFormat: String, Codable, CaseIterable, Sendable {
    case libronixLLS, libronixOEB, legacyLSF

    public var displayName: String {
        switch self {
        case .libronixLLS: "Libronix LLS"
        case .libronixOEB: "Libronix OEB"
        case .legacyLSF: "Logos LSF"
        }
    }
}

/// No import path reports content as readable until the content reader has
/// actually succeeded. Reading metadata is a separate capability.
public enum ResourceSupport: String, Codable, Sendable {
    case metadataOnly, opaqueContainer, invalidFile
}

public enum MetadataProvenance: String, Codable, Sendable {
    case legacyPublicMetadata, libronixMetadata, fileName
}

/// Immutable catalog value. `location` belongs to the user's library; import
/// never transfers ownership or writes to that URL.
public struct LibraryResource: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let location: URL
    public let indexLocation: URL?
    public let title: String
    public let author: String?
    public let languages: [String]
    public let byteCount: Int64
    public let format: ResourceFormat
    public let support: ResourceSupport
    public let provenance: MetadataProvenance
    public let legacyIdentifier: String?
    public let isHelp: Bool
    public let warnings: [String]

    public init(location: URL, indexLocation: URL? = nil, title: String,
                author: String? = nil, languages: [String] = [], byteCount: Int64,
                format: ResourceFormat, support: ResourceSupport,
                provenance: MetadataProvenance, legacyIdentifier: String? = nil,
                isHelp: Bool = false, warnings: [String] = []) {
        self.id = location.standardizedFileURL.path
        self.location = location
        self.indexLocation = indexLocation
        self.title = title
        self.author = author
        self.languages = languages
        self.byteCount = byteCount
        self.format = format
        self.support = support
        self.provenance = provenance
        self.legacyIdentifier = legacyIdentifier
        self.isHelp = isHelp
        self.warnings = warnings
    }

    public var fileName: String { location.lastPathComponent }
}

public struct ImportProgress: Sendable {
    public let completed: Int
    public let total: Int
    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }
}

public struct LibrarySnapshot: Codable, Sendable {
    public let root: URL
    public let resources: [LibraryResource]
    public let discoveredFiles: Int
    public let importDurationSeconds: Double
    public let warnings: [String]

    public init(root: URL, resources: [LibraryResource], discoveredFiles: Int,
                importDurationSeconds: Double, warnings: [String] = []) {
        self.root = root
        self.resources = resources
        self.discoveredFiles = discoveredFiles
        self.importDurationSeconds = importDurationSeconds
        self.warnings = warnings
    }
}
