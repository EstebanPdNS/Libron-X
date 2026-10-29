import Foundation

/// The checked source body is still encoded. It must not be mistaken for a
/// decoded reading projection or flattened with another physical chapter.
public struct ESwordBibleSourceVerse: Sendable, Equatable {
    public let address: BibleCopyAddress
    public let reference: String
    public let sectionOrdinal: Int
    public let encodedBody: String
}

public struct ESwordBiblePassage: Sendable {
    public let resource: LibraryResource
    public let passage: BibleCopyPassage
    public let verses: [ESwordBibleSourceVerse]
    public let sourceStamps: [LibrarySearchFileStamp]
    public let encodedCharacterCount: Int

    /// Recheck after platform decoding, including a journal created since the
    /// read snapshot. SQLite's shared-memory file is not content and is ignored.
    public func verifyUnchanged() throws {
        try Task.checkCancellation()
        guard Self.sourceFiles(resource.location) == sourceStamps.map(\.url) else { throw LegacyIndicesError.sourceChanged }
        try LibrarySearchFileStamp.verify(sourceStamps)
    }
    static func sourceFiles(_ url: URL) -> [URL] {
        [url] + ["-wal", "-journal"].map { URL(fileURLWithPath: url.path + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
