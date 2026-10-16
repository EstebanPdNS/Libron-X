import Foundation

/// Each serialized word/unit has independent lines. Only line zero belongs to
/// the article's flat surface-text coordinates; annotation lines stay local.
public struct LegacyInterlinearRun: Sendable, Codable, Equatable {
    public let token: UInt16
    public let sourceRunFlags: UInt16
    public let attribute: String?
    public let extendedAttributes: LegacyRunAttributes?
    public let mappingFlags: UInt16
    public let declaredCharacterCount: UInt32
    public let sourceField: UInt16
    public let presentLinesMask: UInt32
    public let lines: [LegacyInterlinearLine]
    public let characterOffset: Int
    public let decodedOffset: UInt64
    public let decodedEnd: UInt64
    public let fileOffset: UInt64?
    public var hasLeadingSoftBreak: Bool { sourceRunFlags & 0x20 != 0 }
    public var surfaceText: String { lines.first?.text ?? "" }
    public var surfaceCharacterOffset: Int { characterOffset + (hasLeadingSoftBreak ? 1 : 0) }
    public var logicalText: String { (hasLeadingSoftBreak ? "\u{2028}" : "") + surfaceText }
    public var logicalCharacterCount: Int { logicalText.utf16.count }
}

public struct LegacyInterlinearLine: Sendable, Codable, Equatable {
    public let ordinal: Int
    public let isSerialized: Bool
    public let text: String
    public let runs: [LegacyTextRun]
    public let anchors: [LegacyReferenceAnchor]
    public let markers: [LegacyInlineMarker]
    public let graphics: [LegacyGraphicRun]
    public let interlinears: [LegacyInterlinearRun]
    /// The original copies each four-byte record into two words. Their exact
    /// coordinate interpretation remains separate from preserving the fields.
    public let mappings: [LegacyInterlinearMapping]
}

public struct LegacyInterlinearMapping: Sendable, Codable, Equatable {
    public let first: UInt16
    public let second: UInt16
}
