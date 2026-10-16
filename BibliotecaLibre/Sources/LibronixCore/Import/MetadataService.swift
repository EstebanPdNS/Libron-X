import Foundation

/// Keeps the synchronous, bounded XML reader off the main actor. The returned
/// snapshot is immutable and can be activated with the matching catalog.
public actor MetadataService {
    public init() {}
    public func inspect(at root: URL) throws -> MetadataSnapshot {
        try Task.checkCancellation()
        let snapshot = try MetadataImporter.inspectDirectory(at: root)
        try Task.checkCancellation()
        return snapshot
    }
}
