import AppKit
import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

struct SharedStudyNoteFormatTests {
    @Test func legacySuperscriptNotesAreNormalizedWithoutAdoptingWordsBulletsOrBibleLinks() {
        let font = LegacyFontDescription(values: [12, 0, 0, 0, 400], attributes: [0, 0, 0], family: "Times New Roman", rawFamily: Data())
        func style(_ id: UInt16, _ flags: UInt32) -> LegacyCharacterStyle {
            .init(id: id, version: 1, flags: flags, color: 0, backgroundColor: nil, locale: 1034,
                sourceField: 0, extraField: nil, extraValue: nil, font: font, alternateFont: nil)
        }
        let typography = LegacyTypography(version: 1, fontGroupVersion: 1, fontGroups: [],
            characterStyles: [style(0, 1), style(1, 0)], paragraphStyles: [], opaqueTail: Data())
        let anchor = LegacyReferenceAnchor(reference: "Ge 1:1", flags: 0, dataTypeCode: 16, characterOffset: 0, decodedOffset: 0)
        let labels = ["\u{200b}a\u{200b}", "word", "•", "b", "†"]
        let runs = labels.enumerated().map { index, label in
            LegacyTextRun(text: label, controlToken: 17, styleValue: 0, localeIdentifier: 1034,
                flags: 0, trailingControl: index == 3 ? 1 : 0, attribute: "authored", characterOffset: index * 10,
                fileOffset: nil, decodedOffset: 0)
        }
        let links = labels.enumerated().map { index, label in
            LegacyInlineLink(range: .init(location: index * 10, length: label.utf16.count), label: label,
                sourceName: "authored", sectionOrdinal: index + 1)
        }
        let result = ReaderStudyNoteLinks.classify(links, anchors: [anchor], runs: runs, typography: typography)
        #expect(result[0].role == .studyCommentary && result[4].role == .studyCommentary && result[1...3].allSatisfy { $0.role == nil })
        #expect(zip(result, links).allSatisfy { $0.range == $1.range && $0.target == $1.target && $0.label == $1.label })
        #expect(ReaderStudyNoteLinks.classify(links, anchors: [], runs: runs, typography: typography) == links)
    }
    @Test func printedLegacyRangesKeepOnlyTheirOwnedVerseCoverage() throws {
        let owner = try #require(LegacyPassageQuery.sourceReference("Ge 1:3"))
        #expect(ReaderStudyNoteLinks.headingPassage("g 1.1–3 Authored explanation.", owner: owner)?.end.verse == 3)
        #expect(ReaderStudyNoteLinks.headingPassage("g 1.4–7 Authored explanation.", owner: owner) == nil)
        #expect(ReaderStudyNoteLinks.headingPassage("Authored paragraph with a later 1.1–3 citation.", owner: owner) == nil)
    }

    @MainActor @Test func installedBibleFormatsShareChapterReadingsAndPreserveAllOriginalFragments() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_VERIFY_SHARED_NOTES"] else { return }
        let catalog = try LibronCatalog.load(from: URL(fileURLWithPath: path))
        var checked: [String] = []
        for resource in catalog.resources where resource.libron?.resourceType == "Biblia" {
            guard let url = LibronNativeReader.location(resource) else { continue }
            let db = try LibronNativeDatabase(url)
            let available = try db.chapterReferences()
            guard let first = available.first else { continue }
            var hadNotes = false
            var candidates = [first]
            for wanted in ["Ge 1:1", "Da 7:1", "Ps 119:1", "Jn 3:1", "Re 22:1"] {
                if try db.resolve(wanted) != nil,
                   !candidates.contains(where: { LegacyPassageQuery.sourceReference($0)?.normalizedKey == LegacyPassageQuery.sourceReference(wanted)?.normalizedKey }) { candidates.append(wanted) }
            }
            for first in candidates {
                let query = try #require(LegacyPassageQuery.sourceReference(first))
                var sourcePages: [ReaderPage] = []
                for ordinal in try db.chapterSectionOrdinals(first) {
                    sourcePages.append(try await LibronNativeReader.shared.read(resource, .init(ordinal: ordinal)))
                }
                let links = sourcePages.flatMap { source -> [LegacyInlineLink] in
                    let index = ReaderBibleIndex(anchors: source.content?.anchors ?? [], textLength: source.text.utf16.count)
                    return source.inlineLinks.filter { link in
                        guard link.role == .studyCommentary,
                              let owner = index.reference(at: link.range.location).flatMap(LegacyPassageQuery.sourceReference) else { return false }
                        return owner.sourceBookKey == query.sourceBookKey && owner.chapter == query.chapter
                    }
                }
                guard !links.isEmpty else { continue }
                hadNotes = true
                let chapter = "\(query.sourceBookKey) \(query.chapter):1"
                let page = try await LibronNativeReader.shared.read(resource, .init(ordinal: 0, reference: first, commentaryChapter: chapter))
                for ordinal in Set(links.compactMap(\.sectionOrdinal)) {
                    let note = try await LibronNativeReader.shared.read(resource, .init(ordinal: ordinal))
                    #expect(page.text.contains(note.text), "\(resource.title), \(first): a linked note must survive chapter assembly")
                }
                let references = sourcePages.flatMap { $0.content?.anchors.compactMap { $0.reference.flatMap(LegacyPassageQuery.sourceReference) } ?? [] }
                    .filter { $0.sourceBookKey == query.sourceBookKey && $0.chapter == query.chapter }
                #expect(references.allSatisfy { page.commentaryLocations[$0.normalizedKey] != nil })
                #expect(page.inlineLinks.allSatisfy { Range($0.range, in: page.text) != nil })
                if let rtf = page.content?.richTextRTF {
                    let text = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                    #expect(text.string == page.text)
                }
            }
            if hadNotes { checked.append(resource.title) }
        }
        #expect(checked.contains("Dios Habla Hoy - La Biblia de Estudio"))
        #expect(checked.contains("Reina-Valera 1995 - Edicion de Estudio"))
        #expect(checked.contains("La Biblia de las Américas"))
        #expect(checked.contains("The King James Version"))
        print("Shared annotation format checked across \(checked.count) installed Bible resources: \(checked.joined(separator: "; "))")
    }
}
