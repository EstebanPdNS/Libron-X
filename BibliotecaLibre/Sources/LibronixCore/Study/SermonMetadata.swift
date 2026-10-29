import Foundation

/// User-authored sermon details, separate from imported note provenance.
public struct SermonMetadata: Codable, Equatable, Sendable {
    public var preachedOn: ReadingDay?
    public var speaker = ""
    public var series = ""
    public var venue = ""
    public var passages: [String] = []
    public var tags: [String] = []
    public init() {}
    public var dateText: String {
        preachedOn.map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) } ?? ""
    }
    public func validate() throws {
        guard [speaker, series, venue].allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
              passages.count <= 128, tags.count <= 64,
              tags.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
              Set(tags).count == tags.count else {
            throw PersonalStateError.invalid("Los datos del sermón contienen campos incompatibles.")
        }
        try preachedOn?.validate()
        for passage in passages {
            guard passage.utf8.count <= 4096 else { throw PersonalStateError.tooLarge }
            _ = try BibleReferenceQuery.parse(passage)
        }
    }
}
