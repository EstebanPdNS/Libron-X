import Foundation
import AppKit
import PDFKit
import Testing
@testable import LibronixCore
@testable import BibliotecaMac
import LibronixOutputMac

@MainActor @Suite struct ReaderOutputTests {
    @Test func completeChapterUsesSourceBoundariesAndKeepsFollowingHeadingWithoutNextChapterBody() async throws {
        let fixture = try OutputFixture(); defer { fixture.remove() }
        let doc = try await fixture.prepare()
        #expect(doc.scope == .chapter && doc.sources.map(\.sectionOrdinal) == [0,1,2])
        #expect(doc.references == ["Xy 1:1","Xy 1:2"])
        #expect(doc.plainText == "Own first 🦉.\nOwn second <tag>.\nOwn following heading")
        #expect(!doc.plainText.contains("next chapter"))
        let html = String(decoding:try ReaderOutputEncoder.html(doc),as:UTF8.self)
        #expect(html.contains("&lt;tag&gt;") && !html.contains("<tag>"))
        #expect(!html.contains(doc.bibliographicCitation))
        #expect(String(decoding:ReaderOutputEncoder.text(doc),as:UTF8.self).contains("\r\n"))
    }
    @Test func selectionAndReadingAreDistinctAndInvalidUnicodeSelectionsNeverBecomeOutput() async throws {
        let fixture = try OutputFixture(); defer { fixture.remove() }
        let selected = try await fixture.prepare(.selection(.init(location:4,length:5)))
        #expect(selected.scope == .selection && selected.plainText == "first" && selected.sources.map(\.sectionOrdinal) == [0])
        let full = try await fixture.prepare(); #expect(full.references.count == 2 && full.plainText.contains("second"))
        let emoji = (fixture.text[0] as NSString).range(of:"🦉").location
        await #expect(throws:ReaderOutputError.invalidSelection) { try await fixture.prepare(.selection(.init(location:emoji+1,length:1))) }
        await #expect(throws:ReaderOutputError.invalidSelection) { try await fixture.prepare(.selection(.init(location:0,length:Int.max))) }
        await #expect(throws:ReaderOutputError.invalidSelection) { try await fixture.prepare(.selection(.init(location:0,length:0))) }
    }
    @Test func changedSourceFingerprintBudgetAndBrokenVerseSequenceCannotProduceACompleteChapter() async throws {
        let fixture = try OutputFixture(); defer { fixture.remove() }
        let service = ReaderOutputService()
        await #expect(throws:LegacyIndicesError.sourceChanged) { try await service.prepare(fixture.resource,sectionOrdinal:0,expectedTextFingerprint:"wrong") }
        await #expect(throws:ReaderOutputError.limitExceeded) { try await service.prepare(fixture.resource,sectionOrdinal:0,
            expectedTextFingerprint:LibrarySearchService.textFingerprint(fixture.text[0]),maximumArticles:2) }
        let gap = try OutputFixture(secondVerse:3); defer { gap.remove() }
        await #expect(throws:ReaderOutputError.incompleteChapter) { try await gap.prepare() }
    }
    @Test func typedStylesKeepOriginalFieldsAndAmbiguousPrototypesStayPreserved() throws {
        let parsed = try LegacyTypographyReader.decode(OutputFixture.typography())
        #expect(parsed.characterStyles.count == 2 && parsed.paragraphStyles.count == 1)
        #expect(parsed.characterStyles[1].font.weight == 700 && parsed.characterStyles[1].font.height == 480)
        #expect(parsed.characterStyles[0].font.rawFamily.count == 32 && parsed.opaqueTail.isEmpty)
        let duplicates = try LegacyTypographyReader.decode(OutputFixture.typography(duplicate:true))
        #expect(duplicates.paragraphStyles.count == 2 && duplicates.paragraphStyle(10000) == nil)
        let data = OutputFixture.typography()
        #expect(throws:LegacyTypographyError.self) { try LegacyTypographyReader.decode(Data(data.dropLast())) }
        var future = data; future[0] = 2
        #expect(throws:LegacyTypographyError.unsupportedVersion) { try LegacyTypographyReader.decode(future) }
    }
    @Test func PDFAndRTFUseFrozenOutputContentAndNeverCarryReaderAnnotationAttributes() async throws {
        let fixture = try OutputFixture(); defer { fixture.remove() }
        let source = try await fixture.prepare(.selection(.init(location:4,length:5)))
        let styled = try NativeReaderOutput.attributedText(source,includeCitation:false)
        #expect(styled.string == "first" && styled.attribute(.backgroundColor,at:0,effectiveRange:nil) == nil)
        let rtf = try NativeReaderOutput.rtf(source,includeCitation:false)
        let reloaded = try NSAttributedString(data:rtf,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
        #expect(reloaded.string == styled.string)
        let bytes = try NativeReaderOutput.pdf(source)
        let pdf = try #require(PDFDocument(data:bytes))
        #expect(pdf.pageCount == 1 && pdf.string?.contains("first") == true && pdf.string?.contains("Own following heading") == false)
        #expect(pdf.string?.contains(source.bibliographicCitation) == true)
        #expect(pdf.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String == "Libron-X")
        #expect(abs((pdf.page(at:0)?.bounds(for:.mediaBox).width ?? 0)-ReaderPaper.a4.width) < 0.01)
    }
    @Test func pageSettingsReopenAndRejectFutureStateAndInvalidPaperGeometry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let settings = ReaderOutputSettingsStore(directory:root); var candidate = settings.value
        candidate.paper = .letter; candidate.fontSize = 11; try settings.save(candidate)
        #expect(ReaderOutputSettingsStore(directory:root).value == candidate)
        candidate.leftMargin = 600
        #expect(throws:PersonalStateError.self) { try settings.save(candidate) }
        var edge = ReaderPrintSettings(); edge.topMargin = 0
        #expect(throws:PersonalStateError.self) { try edge.validate() }
        edge.pageNumbers = false; edge.footer = false; edge.bottomMargin = 0
        try edge.validate()
        edge.showTitle = true
        #expect(throws:PersonalStateError.self) { try edge.validate() }
        var future = ReaderPrintSettings(); future.schemaVersion = 2
        let original = try JSONEncoder().encode(future), file = root.appendingPathComponent("print-settings.json"); try original.write(to:file)
        let newer = ReaderOutputSettingsStore(directory:root)
        #expect(newer.errorMessage != nil)
        #expect(throws:PersonalStateError.self) { try newer.save(ReaderPrintSettings()) }
        #expect(try Data(contentsOf:file) == original)
    }
    @Test func canceledPreparationCannotOpenAPreviewAndOutputCommandsFollowTheActiveSurface() async throws {
        let fixture = try OutputFixture(); defer { fixture.remove() }
        let store = LibraryStore(personalDirectory:fixture.root.appendingPathComponent("personal"))
        store.snapshot = LibrarySnapshot(root:fixture.root,resources:[fixture.resource],discoveredFiles:1,importDurationSeconds:0)
        let model = LibraryModel(store:store); model.selection = fixture.resource.id; model.reader.tab = .preview
        model.reader.open(fixture.resource,initialSection:0)
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        while model.reader.isLoading && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(2)) }
        #expect(model.canPrepareOutput)
        model.prepareOutput(.preview); model.output.cancelPreparation(); await Task.yield()
        #expect(!model.output.isPreparing && !model.output.showsPreview && model.output.document == nil)
        model.section = .documents; #expect(!model.canPrepareOutput)
    }
}

struct OutputFixture {
    let root: URL
    let resource: LibraryResource
    let text = ["Own first 🦉.","Own second <tag>.","Own following heading","Own next chapter."]
    init(secondVerse:Int = 2) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("libronx-output-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let identifier = Data([1,0,0,0,3,0,0,0,53,0]), file = root.appendingPathComponent("own.LSF"), index = root.appendingPathComponent("own.LIX")
        let bodies = ["Own first 🦉.","Own second <tag>.","Own following heading","Own next chapter."]
        let references: [String?] = ["Xy 1:1","Xy 1:\(secondVerse)",nil,"Xy 2:1"]
        var tart = Data(), hits = Data(), keys = Data(), named = Data(), labels = Data(), reverse = Data()
        for i in bodies.indices {
            let pointer = tart.count, bytes = Self.article(bodies[i],reference:references[i])
            tart.append(Self.word(0)+Self.integer(UInt32(bytes.count))+bytes)
            hits.append(Self.integer(UInt32(i))+Self.integer(UInt32(pointer))+Self.integer(UInt32(keys.count))+Self.integer(0x80000000)+Self.integer(UInt32(i))+Data([i==0 || i==3 ? 1:0]))
            let title = Array("Own article \(i)".utf16); keys.append(Self.word(UInt16(title.count))); for unit in title { keys.append(Self.word(unit)) }; keys.append(Self.word(0))
            let label = i==0 ? "Xy.CH1" : i==3 ? "Xy.CH2" : "Own.\(i)"
            named.append(Self.integer(UInt32(labels.count))+Self.integer(UInt32(i))); labels.append(Data(label.utf8)+Data([0])); reverse.append(Self.integer(UInt32(i)))
        }
        let data = Self.container("GTTL",chunks:[.init("bkid",identifier),.init("tart",tart),.init("ttbl",Self.typography())])
        try data.write(to:file)
        let aidx = Chunk("AIDX",children:[.init("info",Self.word(0)+Self.integer(4)+Self.integer(4)+Self.word(1)),.init("hlst",hits),.init("klst",keys)])
        let cidx = Chunk("CIDX",children:[.init("info",Self.word(0)+Self.integer(4)),.init("hlst",named),.init("klst",labels),.init("coff",reverse)])
        try Self.container("BIDX",chunks:[.init("bkid",Self.word(1)+identifier),aidx,cidx]).write(to:index)
        resource = LibraryResource(location:file,indexLocation:index,title:"Own output fixture",byteCount:Int64(data.count),format:.legacyLSF,support:.metadataOnly,provenance:.fileName,legacyIdentifier:identifier.map{String(format:"%02x",$0)}.joined())
    }
    func prepare(_ request:ReaderOutputRequest = .reading) async throws -> ReaderOutputDocument {
        try await ReaderOutputService().prepare(resource,sectionOrdinal:0,expectedTextFingerprint:LibrarySearchService.textFingerprint(text[0]),request:request)
    }
    func remove() { UserDefaults.standard.removeObject(forKey:"readerPosition.v1."+resource.id); try? FileManager.default.removeItem(at:root) }
    static func typography(duplicate:Bool = false) -> Data {
        var result = word(1)+word(1)+word(1)+word(8)+Data("Own Text".utf8)+word(5)+Data("Arial".utf8)+word(2)
        for index in 0..<2 {
            result.append(word(1)+integer(index==1 ? 0x4000000:0)+integer(0)+word(1033)+word(0))
            result.append(word(index==1 ? 480:240)+word(0)+word(0)+word(0)+word(index==1 ? 700:400))
            result.append(Data([0,0,0,1,0,0,0,0x20]))
            var family = Data("Arial".utf8); family.append(Data(repeating:0,count:32-family.count)); result.append(family+word(0))
        }
        result.append(word(duplicate ? 2:1))
        for _ in 0..<(duplicate ? 2:1) {
            result.append(word(1)); for _ in 0..<4 { result.append(word(1)+word(1)+word(0)+word(0)+integer(0)) }
            result.append(integer(0)+integer(0))
            for value:UInt16 in [10000,10000,0,0,0,0,0,0,0,3] { result.append(word(value)) }
            result.append(Data("Own".utf8)+word(5)+word(0)+word(0))
        }
        return result
    }
    private static func article(_ text:String,reference:String?) -> Data {
        var data = Data(repeating:0,count:20); put16(17,&data,4); put32(1,&data,6); put16(1,&data,10); put16(1,&data,12); put32(UInt32(text.utf16.count),&data,16)
        data.append(word(1)+word(1)+word(reference==nil ? 1:2)+integer(10000)+word(0)+integer(UInt32(text.utf16.count+1)))
        if let reference { data.append(word(81)+word(128)+word(2)+word(UInt16(reference.utf8.count))+Data(reference.utf8)) }
        data.append(word(17)+word(reference==nil ? 0:0x8000)+word(0)+word(UInt16(text.utf16.count))+word(1033)+Data([0xf0]))
        for unit in text.utf16 { data.append(word(unit)) }; data.append(word(0)); put32(UInt32(data.count),&data,0); return data
    }
    private struct Chunk {
        let tag:String; let data:Data; let children:[Chunk]
        init(_ tag:String,_ data:Data = Data(),children:[Chunk] = []) { self.tag=tag;self.data=data;self.children=children }
        var size:Int { children.isEmpty ? data.count : children.reduce(0){$0+8+$1.size} }
        var count:Int { 1+children.reduce(0){$0+$1.count} }
    }
    private static func container(_ kind:String,chunks:[Chunk]) -> Data {
        let size=18+chunks.reduce(0){$0+$1.count}*18
        var header=Data(repeating:0,count:44),directory=Data(repeating:0,count:18),payload=Data()
        header.replaceSubrange(0..<4,with:Data("LSFF".utf8));header.replaceSubrange(8..<12,with:Data(kind.utf8));header.replaceSubrange(36..<40,with:Data("pcr ".utf8));put32(UInt32(size),&header,40)
        directory.replaceSubrange(0..<4,with:Data("LSFF".utf8));directory.replaceSubrange(4..<8,with:Data(kind.utf8))
        func emit(_ item:Chunk,at:Int) -> Data {
            directory.append(Data(item.tag.utf8)+integer(0)+integer(UInt32(item.size))+integer(UInt32(at+8))+word(UInt16(item.children.count)))
            var result=Data(item.tag.utf8)+integer(UInt32(item.size))
            if item.children.isEmpty { result.append(item.data) } else { for child in item.children { result.append(emit(child,at:at+result.count)) } };return result
        }
        for item in chunks { payload.append(emit(item,at:44+size+payload.count)) }
        var result=header+directory+payload;put32(UInt32(result.count-8),&result,4);return result
    }
    private static func word(_ value:UInt16)->Data { Data([UInt8(truncatingIfNeeded:value),UInt8(truncatingIfNeeded:value>>8)]) }
    private static func integer(_ value:UInt32)->Data { Data((0..<4).map{UInt8(truncatingIfNeeded:value>>($0*8))}) }
    private static func put16(_ value:UInt16,_ data:inout Data,_ at:Int) { data.replaceSubrange(at..<at+2,with:word(value)) }
    private static func put32(_ value:UInt32,_ data:inout Data,_ at:Int) { data.replaceSubrange(at..<at+4,with:integer(value)) }
}
