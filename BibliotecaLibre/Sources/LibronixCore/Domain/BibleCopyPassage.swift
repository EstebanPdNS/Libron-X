import Foundation

public struct BibleCopyAddress: Codable, Equatable, Sendable {
    public let bookKey: String
    public let sourceBook: String
    public let chapter: Int
    public let verse: Int
    public init(_ query:LegacyPassageQuery) {
        bookKey=query.sourceBookKey;sourceBook=query.book;chapter=query.chapter;verse=query.verse
    }
    public var key:String { "\(bookKey) \(chapter):\(verse)" }
    public static func == (lhs:Self,rhs:Self) -> Bool {
        lhs.bookKey==rhs.bookKey && lhs.chapter==rhs.chapter && lhs.verse==rhs.verse
    }
}
public struct BibleCopyPassage: Codable, Equatable, Sendable {
    public let original: String
    public let start: BibleCopyAddress
    public let end: BibleCopyAddress
    public let wholeChapter: Bool
    public static func parse(_ text:String) throws -> BibleCopyPassage {
        guard text.utf16.count <= 512 else { throw BibleCopyError.invalidPassage }
        let parts=text.replacingOccurrences(of:"–",with:"-").replacingOccurrences(of:"—",with:"-").components(separatedBy:"-").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}
        guard (1...2).contains(parts.count), !parts.contains(where:{$0.isEmpty}) else { throw BibleCopyError.invalidPassage }
        let explicitVerse = LegacyPassageQuery.parse(parts[0])
        let chapterOnly = explicitVerse == nil
        guard let first=explicitVerse ?? LegacyPassageQuery.parse(parts[0]+(chapterOnly ? ":1" : "")) else { throw BibleCopyError.invalidPassage }
        guard !chapterOnly || parts.count == 1 else { throw BibleCopyError.invalidPassage }
        var last=first
        if parts.count==2 {
            let suffix=parts[1]
            let expanded = suffix.allSatisfy(\.isNumber) ? "\(first.book) \(first.chapter):\(suffix)" : suffix.first?.isNumber == true ? "\(first.book) \(suffix)" : suffix
            guard let query=LegacyPassageQuery.parse(suffix) ?? LegacyPassageQuery.parse(expanded) else { throw BibleCopyError.invalidPassage };last=query
        }
        if first.sourceBookKey==last.sourceBookKey && (last.chapter < first.chapter || last.chapter==first.chapter && last.verse < first.verse) { throw BibleCopyError.reversedPassage }
        return .init(original:text,start:.init(first),end:.init(last),wholeChapter:chapterOnly)
    }
}

public struct BibleCopyFragment: Sendable, Equatable {
    public let text: String
    public let style: LegacyCharacterStyle?
    public let sourceRange: SearchTextRange
    public let footnote: String?
    public let isBibleText: Bool
    public let isVerseNumber: Bool
}
public struct BibleCopyVerse: Sendable, Equatable {
    public let address: BibleCopyAddress
    public let sourceReference: String
    public let source: ReaderOutputSource
    public let paragraphKey: String
    public let paragraphStyle: LegacyParagraphStyle?
    public let fragments: [BibleCopyFragment]
    public var text:String { fragments.filter{$0.isBibleText && $0.footnote == nil}.map(\.text).joined() }
}
public struct BibleCopyFootnote: Sendable, Equatable {
    public let id: String
    public let marker: String
    public let text: String
    public let source: ReaderOutputSource
}
public struct BibleCopySourceMark: Sendable, Equatable {
    public let offset: Int
    public let address: BibleCopyAddress
}
public struct BibleCopySourceParagraph: Sendable, Equatable {
    public let style: LegacyParagraphStyle?
    public let fragments: [BibleCopyFragment]
    public let marks: [BibleCopySourceMark]
}
public struct BibleCopyDocument: Sendable, Equatable {
    public let resourceID: String
    public let passage: BibleCopyPassage
    public let title: String
    public let abbreviation: String
    public let verses: [BibleCopyVerse]
    public let footnotes: [BibleCopyFootnote]
    public let citation: String
    public let typography: LegacyTypography
    public let sources: [ReaderOutputSource]
    public let fullParagraphs: [ReaderOutputParagraph]
    public let sourceLanguages: [String]
    public var sourceParagraphs: [BibleCopySourceParagraph] = []
    public var hasVerseText: Bool { !verses.isEmpty }
}
