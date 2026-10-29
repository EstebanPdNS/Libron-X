import Foundation

public struct ResearchExcerpt: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var created: Date
    public var sourceTitle: String
    public var text: String
    public var note: String
    public var location: ReaderLocation
    public var selectionLength: Int
    public init(id: UUID = UUID(), created: Date = Date(), sourceTitle: String, text: String, note: String = "", location: ReaderLocation, selectionLength: Int) {
        self.id = id; self.created = created; self.sourceTitle = sourceTitle; self.text = text; self.note = note
        self.location = location; self.selectionLength = selectionLength
    }
    public func validate() throws {
        guard created.timeIntervalSinceReferenceDate.isFinite, !sourceTitle.isEmpty, sourceTitle.utf8.count <= 4096,
              !text.isEmpty, text.utf16.count <= 65_536, note.utf16.count <= 65_536,
              !sourceTitle.contains("\0"), !text.contains("\0"), !note.contains("\0"),
              !location.resourceID.isEmpty, location.resourceID.utf8.count <= 16_384, location.sectionOrdinal >= 0,
              let offset = location.characterOffset, offset >= 0, selectionLength > 0,
              selectionLength == text.utf16.count, offset <= Int.max - selectionLength,
              let fingerprint = location.textFingerprint, fingerprint.count == 64,
              fingerprint.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw PersonalStateError.invalid("El extracto contiene datos incompatibles.")
        }
    }
}
public struct ResearchInbox: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var excerpts: [ResearchExcerpt] = []
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard excerpts.count <= 10_000, Set(excerpts.map(\.id)).count == excerpts.count else { throw PersonalStateError.tooLarge }
        for excerpt in excerpts { try excerpt.validate() }
    }
}
