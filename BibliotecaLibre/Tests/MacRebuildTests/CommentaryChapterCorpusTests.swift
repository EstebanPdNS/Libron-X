import AppKit
import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct CommentaryChapterCorpusTests {
    @Test func everyChapterInBothNativeStudyBiblesKeepsItsNotesLinksImagesAndVersePositions() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_VERIFY_COMMENTARY_CHAPTERS"] else { return }
        let catalog = try LibronCatalog.load(from: URL(fileURLWithPath: path))
        for title in ["The NKJV Study Bible: Second Edition", "NKJV Study Bible, Full-Color"] {
            let resource = try #require(catalog.resources.first { $0.title == title })
            let database = try LibronNativeDatabase(try #require(LibronNativeReader.location(resource)))
            var checked = 0, verses = 0, links = 0, illustrations = 0
            for reference in try database.chapterReferences() {
                let query = try #require(LegacyPassageQuery.sourceReference(reference))
                let chapter = "\(query.sourceBookKey) \(query.chapter):1"
                let source = try await LibronNativeReader.shared.read(resource, .init(ordinal: 0, reference: reference))
                let page = try await LibronNativeReader.shared.read(resource, .init(ordinal: source.destination.ordinal,
                    reference: reference, commentaryChapter: chapter))
                let addresses = source.content?.anchors.compactMap { $0.reference.flatMap(LegacyPassageQuery.sourceReference) } ?? []
                let ordinals = Set(source.inlineLinks.filter { $0.role == .studyCommentary }.compactMap(\.sectionOrdinal) + addresses.compactMap { source.commentaryOrdinals[$0.normalizedKey] }).sorted()
                var expected = "", expectedLinks = 0, expectedImages = 0
                for ordinal in ordinals {
                    let note = try await LibronNativeReader.shared.read(resource, .init(ordinal: ordinal))
                    expected += note.text + "\n"; expectedLinks += note.inlineLinks.count; expectedImages += note.graphics.count
                }
                #expect(page.text == expected, "\(title), \(reference): chapter text must preserve every source note")
                #expect(page.inlineLinks.count == expectedLinks && page.graphics.count == expectedImages)
                #expect(page.inlineLinks.allSatisfy { Range($0.range, in: page.text) != nil })
                #expect(page.graphics.allSatisfy { (0..<page.text.utf16.count).contains($0.graphic.objectCharacterOffset) })
                #expect(addresses.allSatisfy { page.commentaryLocations[$0.normalizedKey].map { (0...page.text.utf16.count).contains($0) } == true })
                if let rtf = page.content?.richTextRTF {
                    let attributed = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                    #expect(attributed.string == page.text)
                }
                checked += 1; verses += addresses.count; links += expectedLinks; illustrations += expectedImages
            }
            #expect(checked == 1189 && verses == 31102)
            print("Commentary chapter corpus: \(title); chapters=\(checked), verse positions=\(verses), links=\(links), images=\(illustrations)")
        }
    }
}
