import Foundation
import CryptoKit
import LibronixCore

/// Immutable, content-addressed personal snapshots. A failed archive prevents
/// rotation of the live file; no previous revision is automatically deleted.
enum PersonalDocumentHistory {
    struct Version: Identifiable {
        let id: String
        let document: StudyDocument
        let date: Date?
        let source: URL
        let fingerprint: String
    }
    struct Report {
        var versions: [Version] = []
        var unreadableSnapshots = 0
        var hasMore = false
    }
    static func archive(_ data: Data, beside personalURL: URL) throws {
        let directory = personalURL.deletingLastPathComponent().appendingPathComponent("personal-history", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(digest(data) + ".json")
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try readBounded(destination) == data else { throw PersonalStateError.concurrentChange }
            return
        }
        // Equal content has the same destination; atomic concurrent writes of
        // that content are equivalent and cannot replace a different revision.
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    static func read(beside personalURL: URL, offset: Int = 0, limit: Int = 20) throws -> Report {
        let manager = FileManager.default, parent = personalURL.deletingLastPathComponent()
        var sources: [URL] = []
        let previous = personalURL.appendingPathExtension("previous")
        if manager.fileExists(atPath: previous.path) { sources.append(previous) }
        for name in ["personal-history", "personal-recovery"] {
            let directory = parent.appendingPathComponent(name, isDirectory: true)
            if manager.fileExists(atPath: directory.path) {
                sources += try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
                    .filter { $0.pathExtension == "json" }
            }
        }
        let dated = try sources.map { url in (url: url, date: try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) }
            .sorted {
                if $0.date == $1.date { return $0.url.path < $1.url.path }
                return ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
            }
        var report = Report(hasMore: dated.count > offset + limit), seen: Set<String> = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for source in dated.dropFirst(offset).prefix(limit) {
            let decoded = Result { () throws -> (Data, WorkspacePersonalSnapshot) in
                let data = try readBounded(source.url)
                let snapshot = try JSONDecoder().decode(WorkspacePersonalSnapshot.self, from: data)
                try snapshot.validate()
                return (data, snapshot)
            }
            switch decoded {
            case .failure: report.unreadableSnapshots += 1
            case .success(let (data, snapshot)):
                let fingerprint = digest(data)
                for document in snapshot.documents {
                    let id = digest(try encoder.encode(document))
                    if seen.insert(id).inserted {
                        report.versions.append(.init(id: id, document: document, date: source.date, source: source.url, fingerprint: fingerprint))
                    }
                }
            }
        }
        return report
    }
    static func verify(_ version: Version) throws -> Data {
        // The source was validated at read time; only its bytes need checking.
        let data = try readBounded(version.source)
        guard digest(data) == version.fingerprint else { throw PersonalStateError.concurrentChange }
        return data
    }
    private static func readBounded(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
        return data
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
