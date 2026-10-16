import Foundation
import Testing
@testable import LibronixCore

struct LegacyIndicesReaderTests {
    @Test func parsesOnlyReferenceSyntaxWithoutAssumingCanonicalBooks() {
        #expect(LegacyObservedBibleReference.parse(" 1Co.13:4 ")?.normalizedKey == "1co 13:4")
        #expect(LegacyObservedBibleReference.parse("Xy 1:2")?.bookCode == "Xy")
        #expect(LegacyObservedBibleReference.parse("Ge 1") == nil)
        #expect(LegacyObservedBibleReference.parse("Ge 0:1") == nil)
        #expect(LegacyObservedBibleReference.parse("Ge 1:1-4") == nil)
    }

    @Test func inspectsSourcePointersTitlesAndEncodedReferenceIDs() throws {
        try withPair { lsf, lix in
            let result = try LegacyIndicesReader.inspect(lsfURL: lsf, lixURL: lix)
            #expect(result.articles.count == 1)
            #expect(result.articles[0].title == "Chapter 1")
            #expect(result.articles[0].relativeTartOffset == 0)
            #expect(result.referencePositions.map(\.referenceID) == [1001, 2002])
            #expect(result.articleReferenceRanges[0].lastReferenceID == 2002)
        }
    }

    @Test func resolvesAnObservedLabelAndUsesItsIndexRange() throws {
        try withPair { lsf, lix in
            let result = try LegacyIndicesReader.resolveObservedReference(lsfURL: lsf, lixURL: lix, reference: " xy.1:2 ")
            #expect(result.match?.observedReference == "Xy 1:2")
            #expect(result.match?.text == "TWO")
            #expect(result.match?.startCharacterOffset == 4)
            #expect(result.match?.endCharacterOffsetExclusive == 7)
            #expect(result.match?.referencePosition?.referenceID == 2002)
        }
    }

    @Test func rejectsAReferenceIndexFromAnotherResource() throws {
        try withPair(indexIDMismatch: true) { lsf, lix in
            #expect(throws: LegacyIndicesError.mismatchedPair) {
                try LegacyIndicesReader.inspect(lsfURL: lsf, lixURL: lix)
            }
        }
    }

    @Test func rejectsAContradictoryArticlePointer() throws {
        try withPair(badPointer: true) { lsf, lix in
            #expect(throws: LegacyIndicesError.articlePointerMismatch(0)) {
                try LegacyIndicesReader.inspect(lsfURL: lsf, lixURL: lix)
            }
        }
    }

    @Test func preservesSelectorAndLiteralTitleSegmentsWithoutCallingThemTranslations() throws {
        try withPair(mixedTitle: true) { lsf, lix in
            let article = try LegacyIndicesReader.inspect(lsfURL: lsf, lixURL: lix).articles[0]
            #expect(article.title == "First / Second")
            #expect(article.titleSegments.map(\.selectorCode) == [1033, nil, 513])
        }
    }

    @Test func reportsAnIncompleteBoundedSearchAsIncomplete() throws {
        try withPair(twoArticles: true) { lsf, lix in
            let bounded = try LegacyIndicesReader.resolveObservedReference(lsfURL: lsf, lixURL: lix,
                                                                           reference: "Ab 1:2", maximumCandidates: 1)
            #expect(bounded.match == nil)
            #expect(bounded.candidatesExamined == 1)
            #expect(bounded.totalCandidates == 2)
            #expect(!bounded.exhaustedCandidates)
            let full = try LegacyIndicesReader.resolveObservedReference(lsfURL: lsf, lixURL: lix,
                                                                        reference: "Ab 1:2", maximumCandidates: 2)
            #expect(full.match?.articleID == 1)
            #expect(full.match?.text == "TWO")
        }
    }

    @Test func malformedTitleLengthFailsWithoutAllocatingFromItsValue() throws {
        try withPair(badTitle: true) { lsf, lix in
            #expect(throws: LegacyIndicesError.invalidTable("klst/title")) {
                try LegacyIndicesReader.inspect(lsfURL: lsf, lixURL: lix)
            }
        }
    }

    @Test func invalidCharacterRangeBecomesADiagnosticInsteadOfIncorrectText() throws {
        try withPair(badRange: true) { lsf, lix in
            let result = try LegacyIndicesReader.resolveObservedReference(lsfURL: lsf, lixURL: lix, reference: "Xy 1:2")
            #expect(result.match == nil)
            #expect(result.diagnostics.contains { $0.contains("invalidReferenceRange") })
        }
    }

    @Test func refusesToReturnPartialTextForACrossArticleIndexRange() throws {
        try withPair(twoArticles: true, crossArticleRange: true) { lsf, lix in
            let result = try LegacyIndicesReader.resolvePassage(lsfURL: lsf, lixURL: lix, reference: "Xy 1:1")
            #expect(result.match == nil)
            #expect(result.diagnostics.contains { $0.contains("crossArticleReferenceUnsupported") })
        }
    }

    @Test func acceptsSpanishEnglishMultiwordAndNumberedBookNames() {
        #expect(LegacyPassageQuery.parse("Génesis 1:1")?.normalizedKey == "ge 1:1")
        #expect(LegacyPassageQuery.parse("Genesis 1:1")?.normalizedKey == "ge 1:1")
        #expect(LegacyPassageQuery.parse("1 Corintios 13:4")?.normalizedKey == "1co 13:4")
        #expect(LegacyPassageQuery.parse("II Samuel 2:1")?.normalizedKey == "2sa 2:1")
        #expect(LegacyPassageQuery.parse("Cantar de los Cantares 1:1")?.normalizedKey == "so 1:1")
        #expect(LegacyPassageQuery.parse("Song of Solomon 1:1")?.normalizedKey == "so 1:1")
        #expect(LegacyPassageQuery.parse("Apocalipsis 22:21")?.normalizedKey == "re 22:21")
        #expect(LegacyPassageQuery.parse("Génesis 1:1-5") == nil)
        #expect(LegacyPassageQuery.parse("John 0:1") == nil)
        #expect(LegacyPassageQuery.parse("A " + String(repeating: "9", count: 1000) + ":1") == nil)
    }

    @Test func resolvesHumanNamesOnlyThroughAnActualObservedAnchor() throws {
        try withPair(firstBookCode: "Ge") { lsf, lix in
            for name in ["Génesis", "Genesis", "Gn", "Gen."] {
                let result = try LegacyIndicesReader.resolvePassage(lsfURL: lsf, lixURL: lix, reference: name + " 1:2")
                #expect(result.match?.text == "TWO")
                #expect(result.match?.observedReference == "Ge 1:2")
            }
            let absent = try LegacyIndicesReader.resolvePassage(lsfURL: lsf, lixURL: lix, reference: "John 1:2")
            #expect(absent.match == nil)
            #expect(absent.exhaustedCandidates)
            // The exact-source API does not silently translate names.
            #expect(try LegacyIndicesReader.resolveObservedReference(lsfURL: lsf, lixURL: lix,
                reference: "Genesis 1:2").match == nil)
        }
    }

    @Test func preservesDuplicateSourceRowsAndUsesCheckedNamedPositions() throws {
        try withPair(duplicateDirectoryRow: true) { lsf, lix in
            let index = try LegacyIndicesReader.inspect(lsfURL: lsf, lixURL: lix)
            #expect(index.namedPositions.map(\.label) == ["CH1"])
            let directory = try LegacyIndicesReader.articleDirectory(lsfURL: lsf, lixURL: lix)
            #expect(directory.entries.count == 2)
            #expect(directory.entries.map(\.id) == [0, 1])
            #expect(directory.entries.map(\.sectionOrdinal) == [0, 0])
            #expect(directory.entries.map(\.level) == [1, 0])
            #expect(directory.entries.allSatisfy { $0.positionLabel == "CH1" && $0.title == "Chapter 1" })
            #expect(directory.entries(forSectionOrdinal: 0).count == 2)
            #expect(directory.entry(forDirectoryRow: 1)?.articleID == 0)
            #expect(directory.entry(forDirectoryRow: 2) == nil)
            #expect(directory.entries[0].section.headerOffset == directory.sections.tartOffset)
        }
    }

    @Test func acceptsAbsentOptionalPositionsAndReportsTheirAbsence() throws {
        try withPair(omitCIDX: true) { lsf, lix in
            let directory = try LegacyIndicesReader.articleDirectory(lsfURL: lsf, lixURL: lix)
            #expect(directory.namedPositionCount == 0)
            #expect(directory.entries[0].positionLabel == nil)
            #expect(directory.warnings.contains { $0.contains("CIDX") })
        }
    }

    @Test func rejectsContradictoryCIDXInversePermutationAndUnterminatedLabels() throws {
        try withPair(twoArticles: true, cidxBadReverse: true) { lsf, lix in
            #expect(throws: LegacyIndicesError.invalidTable("CIDX/coff")) {
                try LegacyIndicesReader.inspect(lsfURL: lsf, lixURL: lix)
            }
        }
        try withPair(twoArticles: true, cidxDuplicateID: true) { lsf, lix in
            #expect(throws: LegacyIndicesError.invalidTable("CIDX/position")) {
                try LegacyIndicesReader.inspect(lsfURL: lsf, lixURL: lix)
            }
        }
        try withPair(cidxUnterminatedLabel: true) { lsf, lix in
            #expect(throws: LegacyIndicesError.invalidTable("CIDX/position")) {
                try LegacyIndicesReader.inspect(lsfURL: lsf, lixURL: lix)
            }
        }
    }

    @Test func chapterTitlePriorityNeverExcludesOtherSourceArticles() throws {
        try withPair(twoArticles: true, secondTitleChapter: 2) { lsf, lix in
            let result = try LegacyIndicesReader.resolvePassage(lsfURL: lsf, lixURL: lix,
                reference: "Ab 1:2", maximumCandidates: 2)
            #expect(result.totalCandidates == 2)
            #expect(result.match?.articleID == 1)
            #expect(result.match?.text == "TWO")
        }
    }
    @Test func chapterNumbersBeforeDescriptiveTitlesStillPrioritizeActualAnchors() throws {
        try withPair(twoArticles: true, firstTitle: "Psalm 2 - A descriptive heading", secondTitle: "Psalm 1 - Another heading") { lsf, lix in
            let result = try LegacyIndicesReader.resolvePassage(lsfURL: lsf, lixURL: lix,
                reference: "Ab 1:2", maximumCandidates: 1)
            #expect(result.match?.articleID == 1 && result.candidatesExamined == 1)
            #expect(result.match?.observedReference == "Ab 1:2")
        }
    }

    @Test func actorInvalidatesBothIndexAndSectionCachesWhenFilesChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lsf = directory.appendingPathComponent("sample.LSF"), lix = directory.appendingPathComponent("sample.LIX")
        func replacePair(twoArticles: Bool) throws {
            try withPair(twoArticles: twoArticles) { source, index in
                try Data(contentsOf: source).write(to: lsf)
                try Data(contentsOf: index).write(to: lix)
            }
        }
        try replacePair(twoArticles: false)
        let service = LegacyContentService()
        #expect(try await service.directory(lsf).entries.count == 1)
        #expect(try await service.read(lsf, directoryRow: 0).anchors[0].reference == "Xy 1:1")
        try replacePair(twoArticles: true)
        #expect(try await service.directory(lsf).entries.count == 2)
        #expect(try await service.inspect(lsf).sections.count == 2)
        #expect(try await service.resolvePassage(lsf, reference: "Ab 1:2").match?.articleID == 1)
        await service.clearCache()
        #expect(try await service.read(lsf, ordinal: 1).anchors[0].reference == "Ab 1:1")
    }

    private struct Chunk {
        let tag: String
        let data: Data
        let children: [Chunk]
        init(_ tag: String, _ data: Data = Data(), children: [Chunk] = []) {
            self.tag = tag
            self.data = data
            self.children = children
        }
        var payloadSize: Int { children.isEmpty ? data.count : children.reduce(0) { $0 + 8 + $1.payloadSize } }
        var entryCount: Int { 1 + children.reduce(0) { $0 + $1.entryCount } }
    }

    private func withPair(indexIDMismatch: Bool = false, badPointer: Bool = false, mixedTitle: Bool = false,
                          twoArticles: Bool = false, badTitle: Bool = false, badRange: Bool = false,
                          firstBookCode: String = "Xy", duplicateDirectoryRow: Bool = false, omitCIDX: Bool = false,
                          crossArticleRange: Bool = false,
                          cidxBadReverse: Bool = false, cidxDuplicateID: Bool = false, cidxUnterminatedLabel: Bool = false,
                          secondTitleChapter: Int = 1,
                          firstTitle: String = "Chapter 1", secondTitle: String? = nil,
                          _ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lsf = directory.appendingPathComponent("sample.LSF"), lix = directory.appendingPathComponent("sample.LIX")
        let identifier = Data([1, 0, 0, 0, 3, 0, 0, 0, 53, 0])
        let documents = twoArticles ? [article(firstBookCode), article("Ab")] : [article(firstBookCode)]
        var tart = Data(), relativeOffsets: [Int] = []
        for document in documents {
            relativeOffsets.append(tart.count)
            tart.append(le16(0) + le32(UInt32(document.count)) + document)
        }
        try container("GTTL", chunks: [Chunk("bkid", identifier), Chunk("tart", tart)]).write(to: lsf)
        var indexID = Data([1, 0]) + identifier
        if indexIDMismatch { indexID[2] = 9 }
        let title: Data
        if badTitle { title = le16(UInt16.max) }
        else {
            var units: [UInt16] = []
            if mixedTitle {
                units.append(contentsOf: [1, 1033])
                units.append(contentsOf: "First".utf16)
                units.append(2)
                units.append(contentsOf: " / ".utf16)
                units.append(contentsOf: [1, 513])
                units.append(contentsOf: "Second".utf16)
                units.append(2)
            } else {
                units = Array(firstTitle.utf16)
            }
            title = le16(UInt16(units.count)) + units.reduce(into: Data()) { $0.append(le16($1)) } + le16(0)
        }
        let secondTitleUnits = Array((secondTitle ?? "Chapter \(secondTitleChapter)").utf16)
        let secondTitleData = le16(UInt16(secondTitleUnits.count)) + secondTitleUnits.reduce(into: Data()) { $0.append(le16($1)) } + le16(0)
        let allTitles = title + secondTitleData
        var articleHits = Data(), positionHits = Data(), rangeHits = Data()
        for index in documents.indices {
            let id = UInt32(index)
            articleHits.append(le32(id) + le32(UInt32(relativeOffsets[index] + (badPointer ? 1 : 0))) +
                               le32(index == 0 ? 0 : UInt32(title.count)) + le32(0x80000000) + le32(id) + Data([1]))
            let base = UInt16(index * 2002)
            positionHits.append(le16(base + 1001) + le32(id) + le32(0) + le32(crossArticleRange && index == 0 ? 1 : id) + le32(3))
            positionHits.append(le16(base + 2002) + le32(id) + le32(4) + le32(id) + le32(badRange ? UInt32.max : 6))
            rangeHits.append(le32(id) + le16(base + 1001) + le16(base + 2002))
        }
        if duplicateDirectoryRow {
            articleHits.append(le32(0) + le32(0) + le32(0) + le32(0x80000000) + le32(0) + Data([0]))
        }
        let count = UInt32(documents.count)
        let rowCount = count + (duplicateDirectoryRow ? 1 : 0)
        let aidx = Chunk("AIDX", children: [Chunk("info", le16(0) + le32(rowCount) + le32(count) + le16(1)),
                                            Chunk("klst", allTitles), Chunk("hlst", articleHits)])
        let rtax = Chunk("RTAX", children: [Chunk("info", le16(0) + le32(count * 2)), Chunk("hlst", positionHits)])
        let atrx = Chunk("ATRX", children: [Chunk("info", le16(0) + le32(count)), Chunk("hlst", rangeHits)])
        var labels = Data(), namedHits = Data(), inverse = Data()
        for index in documents.indices.reversed() {
            let label = "CH\(index + 1)"
            namedHits.append(le32(UInt32(labels.count)) + le32(cidxDuplicateID ? 0 : UInt32(index)))
            labels.append(Data(label.utf8))
            if !cidxUnterminatedLabel { labels.append(0) }
        }
        for index in documents.indices { inverse.append(le32(cidxBadReverse ? 0 : UInt32(documents.count - 1 - index))) }
        let cidx = Chunk("CIDX", children: [Chunk("info", le16(0) + le32(count)), Chunk("hlst", namedHits),
                                          Chunk("klst", labels), Chunk("coff", inverse)])
        var chunks = [Chunk("bkid", indexID), aidx, rtax, atrx]
        if !omitCIDX { chunks.append(cidx) }
        try container("BIDX", chunks: chunks).write(to: lix)
        try body(lsf, lix)
    }

    private func article(_ book: String) -> Data {
        func anchor(_ value: String) -> Data { le16(81) + le16(128) + le16(2) + le16(UInt16(value.utf8.count)) + Data(value.utf8) }
        func run(_ value: String) -> Data { le16(17) + le16(0) + le16(0) + le16(UInt16(value.utf8.count)) + le16(1033) + Data([0]) + Data(value.utf8) + le16(0) }
        var data = Data(repeating: 0, count: 20)
        put16(17, &data, 4)
        put32(1, &data, 6)
        put16(1, &data, 10)
        put16(1, &data, 12)
        put32(7, &data, 16)
        data.append(le16(1) + le16(1) + le16(4) + le32(10000) + le16(0) + le32(8))
        data.append(anchor(book + " 1:1") + run("ONE ") + anchor(book + " 1:2") + run("TWO"))
        put32(UInt32(data.count), &data, 0)
        return data
    }

    private func container(_ kind: String, chunks: [Chunk]) -> Data {
        let entries = chunks.reduce(0) { $0 + $1.entryCount }
        let directorySize = 18 + entries * 18
        var header = Data(repeating: 0, count: 44)
        header.replaceSubrange(0..<4, with: Data("LSFF".utf8))
        header.replaceSubrange(8..<12, with: Data(kind.utf8))
        header.replaceSubrange(36..<40, with: Data("pcr ".utf8))
        put32(UInt32(directorySize), &header, 40)
        var directory = Data(repeating: 0, count: 18)
        directory.replaceSubrange(0..<4, with: Data("LSFF".utf8))
        directory.replaceSubrange(4..<8, with: Data(kind.utf8))
        var payload = Data()
        func emit(_ chunk: Chunk, absoluteOffset: Int) -> Data {
            directory.append(Data(chunk.tag.utf8) + le32(0) + le32(UInt32(chunk.payloadSize)) +
                             le32(UInt32(absoluteOffset + 8)) + le16(UInt16(chunk.children.count)))
            var result = Data(chunk.tag.utf8) + le32(UInt32(chunk.payloadSize))
            if chunk.children.isEmpty { result.append(chunk.data) }
            else {
                for child in chunk.children { result.append(emit(child, absoluteOffset: absoluteOffset + result.count)) }
            }
            return result
        }
        for chunk in chunks { payload.append(emit(chunk, absoluteOffset: 44 + directorySize + payload.count)) }
        var file = header + directory + payload
        put32(UInt32(file.count - 8), &file, 4)
        return file
    }

    private func le16(_ value: UInt16) -> Data { Data([UInt8(value & 255), UInt8(value >> 8)]) }
    private func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> UInt32($0 * 8)) & 255) }) }
    private func put16(_ value: UInt16, _ data: inout Data, _ at: Int) { data.replaceSubrange(at..<(at + 2), with: le16(value)) }
    private func put32(_ value: UInt32, _ data: inout Data, _ at: Int) { data.replaceSubrange(at..<(at + 4), with: le32(value)) }
}
