import Foundation

/// Each process owns a disposable private cache. Embedded LSF/LIX files keep
/// their edition pairing; their original resource container is never modified.
public actor LibronixBookService {
    public static let shared = LibronixBookService()
    private let root: URL
    private struct Cached: Sendable {
        let stamp: LegacyGraphicSourceStamp
        let resource: LibraryResource
        let metadata: LibronixBookMetadata
    }
    private var resources: [URL: Cached] = [:]
    private struct Preparation {
        let stamp: LegacyGraphicSourceStamp
        let id: UUID
        let task: Task<Cached, any Error>
    }
    private var preparations: [URL: Preparation] = [:]
    public init(cacheDirectory: URL? = nil) {
        root = (cacheDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("libronx-books-" + UUID().uuidString, isDirectory: true)
    }
    deinit {
        for preparation in preparations.values { preparation.task.cancel() }
        try? FileManager.default.removeItem(at: root)
    }

    public func metadata(_ resource: LibraryResource) throws -> LibronixBookMetadata {
        let stamp = try LegacyGraphicsService.fileStamp(resource.location)
        if let cached = resources[resource.location], cached.stamp == stamp { return cached.metadata }
        return try LibronixBookArchive.inspect(at: resource.location).metadata()
    }

    public func prepare(_ resource: LibraryResource) async throws -> LibraryResource {
        try Task.checkCancellation()
        guard resource.format == .libronixLLS else { throw LibronixBookError.unsupportedArchive }
        let stamp = try LegacyGraphicsService.fileStamp(resource.location)
        if let cached = resources[resource.location], cached.stamp == stamp { return cached.resource }
        let preparation: Preparation
        if let existing = preparations[resource.location], existing.stamp == stamp { preparation = existing }
        else {
            let root = root
            preparation = Preparation(stamp:stamp,id:UUID(),task:Task.detached(priority:Task.currentPriority) {
                try Self.materialize(resource, root:root, stamp:stamp)
            })
            preparations[resource.location] = preparation
        }
        do {
            let cached = try await preparation.task.value
            guard try LegacyGraphicsService.fileStamp(resource.location) == stamp else { throw LibronixBookError.sourceChanged }
            if preparations[resource.location]?.id == preparation.id {
                resources[resource.location] = cached
                preparations[resource.location] = nil
            }
            // One canceled caller must not cancel preparation needed by other
            // readers. Publish the shared valid cache, then honor that caller.
            try Task.checkCancellation()
            return cached.resource
        } catch {
            if preparations[resource.location]?.id == preparation.id { preparations[resource.location] = nil }
            throw error
        }
    }

    private nonisolated static func materialize(_ resource: LibraryResource, root: URL,
                                               stamp: LegacyGraphicSourceStamp) throws -> Cached {
        try Task.checkCancellation()
        let archive = try LibronixBookArchive.inspect(at: resource.location)
        let texts = archive.entries.filter { $0.path.lowercased().hasSuffix(".lsf") }
        guard texts.count == 1, let text = texts.first,
              let index = archive.entries.first(where: { $0.path.lowercased() == String(text.path.dropLast(4)).lowercased() + ".lix" }) else { throw LibronixBookError.missingText }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let textURL = folder.appendingPathComponent("resource.LSF"), indexURL = folder.appendingPathComponent("resource.LIX")
        do {
            try archive.copyEntry(text.path, to: textURL); try archive.copyEntry(index.path, to: indexURL)
            let metadata = try LegacyResourceReader.inspect(lsfURL: textURL, lixURL: indexURL, allowUnavailableIndexBlocks: true)
            guard metadata.identifiersMatch == true else { throw LibronixBookError.invalidDirectory }
            let inner = LibraryResource(location: textURL, indexLocation: indexURL,
                title: resource.title, author: resource.author, languages: resource.languages, byteCount: Int64(text.length),
                format: .legacyLSF, support: .metadataOnly, provenance: .legacyPublicMetadata,
                legacyIdentifier: metadata.lsf.bkidHex, isHelp: resource.isHelp, warnings: metadata.warnings)
            guard try LegacyGraphicsService.fileStamp(resource.location) == stamp else { throw LibronixBookError.sourceChanged }
            let document = try archive.metadata()
            guard try LegacyGraphicsService.fileStamp(resource.location) == stamp else { throw LibronixBookError.sourceChanged }
            return Cached(stamp: stamp, resource: inner, metadata:document)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}
