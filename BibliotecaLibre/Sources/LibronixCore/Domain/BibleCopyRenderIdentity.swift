import Foundation

/// Only editable rendering fields participate. A provenance XML tree can be
/// large; it is immutable evidence, not a SwiftUI task key to serialize again.
public struct BibleCopyRenderIdentity: Hashable, Sendable {
    private let id: UUID
    private let version: Int
    private let name: String
    private let preset: String?
    private let sourceHash: String?
    private let characterFormatting: Bool
    private let paragraphFormatting: Bool
    private let redLetter: Bool
    private let citation: Bool
    private let footnotes: Bool
    private let bibleOnly: Bool
    private let paragraphs: String
    private let beforePassage: BibleCopyOutputTemplate
    private let afterPassage: BibleCopyOutputTemplate
    private let beforeVerse: BibleCopyOutputTemplate
    private let afterVerse: BibleCopyOutputTemplate
    private let greek: String
    private let hebrew: String
    private let letters: String

    public init(_ style: BibleCopyOutputStyle) {
        id = style.id; version = style.schemaVersion; name = style.name
        preset = style.preset; sourceHash = style.sourceSHA256
        characterFormatting = style.characterFormatting
        paragraphFormatting = style.paragraphFormatting
        redLetter = style.redLetter; citation = style.citation
        footnotes = style.copyFootnotes; bibleOnly = style.bibleTextOnly
        paragraphs = style.paragraphs.rawValue
        beforePassage = style.beforePassage; afterPassage = style.afterPassage
        beforeVerse = style.beforeVerse; afterVerse = style.afterVerse
        greek = style.greek.rawValue; hebrew = style.hebrew.rawValue
        letters = style.hebrewLetters.rawValue
    }
}

public actor BibleCopyFormattingService {
    public init() {}
    public func format(_ source: BibleCopyDocument, style: BibleCopyOutputStyle,
                       language: BibleCopyReferenceLanguage) throws -> BibleCopyFormattedDocument {
        try Task.checkCancellation()
        return try BibleCopyFormatter.format(source, style: style, referenceLanguage: language)
    }
}
