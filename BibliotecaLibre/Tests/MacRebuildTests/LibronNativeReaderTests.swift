import AppKit
import Foundation
import Testing
import LibronixCore
import CSQLite
@testable import MacRebuild

@MainActor struct LibronNativeReaderTests {
    @Test func completeBibleConversionPreservesFormattingAndCanonicalNavigation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("fixture.bbli")
        var db: OpaquePointer?
        #expect(sqlite3_open(source.path,&db) == SQLITE_OK)
        let sql = "CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Bible','T','Fixture'); CREATE TABLE Bible(Book,Chapter,Verse,Scripture); INSERT INTO Bible VALUES(1,1,1,'<b>In the beginning</b> 😀'),(1,1,2,'Second verse'),(1,2,1,'Next chapter'),(43,3,1,'John chapter three');"
        #expect(sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK);sqlite3_close(db)
        let original = try ESwordResource.inspect(source)
        let package = try LibronPackage.create(original,in:root.appendingPathComponent("Library"),backup:false)
        let resource = try LibronPackage.read(package).1
        let old = try await ReaderSession.readOriginal(resource,.init(ordinal:0,reference:"Ge 1:1"))
        let receipt = try #require(try await LibronNativeNormalizer().convert(resource))
        #expect(receipt.state == "complete" && receipt.checkedSections == 3)
        var previous = receipt;previous.converterVersion = 1
        try JSONEncoder().encode(previous).write(to:package.appendingPathComponent("normalized/conversion.json"),options:.atomic)
        let rebuilt = try await LibronNativeNormalizer().convert(resource)
        #expect(rebuilt?.converterVersion == 2)
        #expect(try LibronPackage.read(package,verify:true).0.normalizedContent != nil)
        let result = try await ReaderSession.read(resource,.init(ordinal:0,reference:"Ge 1:1"))
        #expect(result.text == old.text)
        #expect(result.content?.plainText == old.content?.plainText)
        #expect(result.selection?.location == old.selection?.location)
        #expect(result.selection?.length ?? 0 > 0)
        #expect(try await ReaderSession.read(resource,.init(ordinal:0,reference:"Jn 3:1")).text.contains("John chapter three"))
        let chapters = try await BibleChapterCatalog().books(in:resource)
        #expect(chapters.first?.chapters == [1,2])
        let passage = try await ReaderSession.read(resource,.init(ordinal:0,reference:"Ge 1:1",endReference:"Ge 2:1"))
        #expect(passage.passageParts.count == 2)
        #expect(passage.destination.passageStartReference == "Ge 1:1")
        let continuation = try await ReaderSession.read(resource,.init(ordinal:1,reference:"Ge 2:1",endReference:"Ge 2:1",passageStartReference:"Ge 1:1"))
        #expect(continuation.passageParts.count == 2 && continuation.destination.ordinal == 1)

        #expect(try LibronPackage.hash(source) == LibronPackage.hash(resource.location))
        let find = try await ReaderFindSource.find(resource,.init(query:"Next chapter",ordinal:0,position:0))
        #expect(find?.ordinal == 1)
        await #expect(throws:(any Error).self) { try await ReaderSession.read(resource,.init(ordinal:0,reference:"Ge 999:1")) }
    }
    @Test func actualManagedCorpusRetainsNativePagesAndBibleDestinations() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_VERIFY_NATIVE_CORPUS"] else { return }
        let resources = try LibronCatalog.load(from:URL(fileURLWithPath:path)).resources
        for resource in resources {
            if let titles = ProcessInfo.processInfo.environment["LIBRONX_VERIFY_NATIVE_RESOURCE"], !titles.components(separatedBy:"|").contains(resource.title) { continue }
            if ProcessInfo.processInfo.environment["LIBRONX_VERIFY_NATIVE_PARTIAL"] == "1" {
                guard LibronNativeReader.location(resource) != nil else { continue }
                if resource.format == .eSwordSQLite {
                    guard let package = resource.packageLocation,
                          let data = try? Data(contentsOf:package.appendingPathComponent("normalized/conversion.json")),
                          let receipt = try? JSONDecoder().decode(LibronNormalizationReceipt.self,from:data),receipt.converterVersion == 2 else { continue }
                }
            }
            #expect(LibronNativeReader.location(resource) != nil,"Missing native content: \(resource.title)")
            let first = try await ReaderSession.readOriginal(resource,.init(ordinal:0))
            for ordinal in Set([0,first.sectionCount-1]) {
                let original = ordinal == 0 ? first : try await ReaderSession.readOriginal(resource,.init(ordinal:ordinal))
                let native = try await ReaderSession.read(resource,.init(ordinal:ordinal))
                #expect(native.text == original.text,"Body differs: \(resource.title) #\(ordinal)")
                #expect(native.content?.anchors == original.content?.anchors,"Anchors differ: \(resource.title)")
                if original.entries.isEmpty, LibronDictionaryIndex.supports(resource) {
                    #expect(native.entries.allSatisfy { (0..<native.sectionCount).contains($0.ordinal) })
                } else { #expect(native.entries.map(\.title) == original.entries.map(\.title),"Contents differ: \(resource.title)") }
                if let html = original.oeb { #expect(native.oeb?.book.members == html.book.members) }
            }
            if resource.libron?.resourceType == "Biblia" {
                let books = try await BibleChapterCatalog.shared.books(in:resource)
                for book in [books.first,books.last].compactMap({ $0 }) {
                    guard let chapter = book.chapters.first else { continue }
                    let request = ReaderDestination(ordinal:0,reference:book.reference(chapter:chapter))
                    print("Verify Bible reference: \(resource.title) \(request.reference ?? "")")
                    let native = try await ReaderSession.read(resource,request)
                    do {
                        let original = try await ReaderSession.readOriginal(resource,request)
                        #expect(native.destination.ordinal == original.destination.ordinal,"Bible position differs: \(resource.title)")
                        #expect(native.selection?.location == original.selection?.location)
                        if resource.format == .legacyLSF || resource.format == .libronixLLS { #expect(native.selection == original.selection) }
                    } catch RebuildError.referenceSearchIncomplete {
                        // The old resolver is bounded. Independently verify the new
                        // destination against the source article and its real anchor.
                        let original = try await ReaderSession.readOriginal(resource,.init(ordinal:native.destination.ordinal))
                        #expect(native.text == original.text)
                        let key = request.reference.flatMap(LegacyPassageQuery.navigationInput)?.normalizedKey
                        #expect(original.content?.anchors.contains(where: { $0.reference.flatMap(LegacyPassageQuery.sourceReference)?.normalizedKey == key && $0.characterOffset == native.selection?.location }) == true)
                        print("Native reference verified by source anchor beyond old resolver limit: \(resource.title) \(request.reference ?? "")")
                    }

                }
            }
            print("Native corpus verified: \(resource.title)")
        }
    }

    @Test func largeRealConcordanceSectionsRetainTheirCompleteText() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_INSPECT_STRONG"] else { return }
        let resources = try LibronCatalog.load(from:URL(fileURLWithPath:path)).resources
        let resource = try #require(resources.first { $0.location.lastPathComponent == "STRCONCES.lbxlls" })
        let inner = try await LibronixBookService.shared.prepare(resource)
        let index = try LegacyContentReader.inspectSections(lsfURL:inner.location)
        let large = index.sections.filter { $0.decodedLength > 1024 * 1024 }
        #expect(!large.isEmpty)
        for descriptor in large {
            let page = try await ReaderSession.readOriginal(resource,.init(ordinal:descriptor.ordinal))
            #expect(!page.text.isEmpty && page.content?.plainText == page.text)
            print("Strong section \(descriptor.ordinal): decoded=\(descriptor.decodedLength) UTF16=\(page.text.utf16.count) runs=\(page.content?.runs.count ?? 0)")
        }

    }

    @Test func inspectTeacherStructureWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_INSPECT_TEACHER"] else { return }
        let resources = try LibronCatalog.load(from:URL(fileURLWithPath:path)).resources
        let resource = try #require(resources.first { $0.location.lastPathComponent == "TEACHCOM.lbxlls" })
        let inner = try await LibronixBookService.shared.prepare(resource)
        let index = try LegacyContentReader.inspectSections(lsfURL:inner.location)
        let descriptor = index.sections[807]
        let page = try await ReaderSession.readOriginal(resource,.init(ordinal:807))
        #expect(!page.text.isEmpty)
        let embedded = try #require(page.graphics.first { $0.graphic.embeddedFormat == "wmf" })
        #expect(embedded.graphic.embeddedData?.count == 40960)
        #expect(embedded.name.hasSuffix(".bmp"))
        #expect(NSImage(data:embedded.data) != nil)
        let data = try LegacyContentReader.decodedSectionPayload(lsfURL:inner.location,ordinal:807)
        let offset = 4863606 - Int(descriptor.payloadOffset)
        print("Teacher section 807: stored=\(descriptor.storedLength) decoded=\(descriptor.decodedLength) relativeFailure=\(offset)")
        print("Header: \(data.prefix(48).map { String(format:"%02x",$0) }.joined())")
        if offset >= 0, offset < data.count {
            func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at+1]) << 8 }
            func u32(_ at: Int) -> Int { u16(at) | u16(at+2) << 16 }
            let length = u32(offset+10), base = offset+14
            var at = base+18, records: [String:Int] = [:]
            while at+6 <= base+length {
                let size = u32(at)*2, function = u16(at+4)
                guard size >= 6, at+size <= base+length else { break }
                records[String(format:"%04x",function),default:0] += 1
                if function == 0 { break };at += size
            }
            print("WMF bytes \(length), records \(records)")
            print("Structure context: \(data[max(0,offset-20)..<min(data.count,offset+40)].map { String(format:"%02x",$0) }.joined())")
        }
    }

    @Test func inspectMoodyStructureWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_INSPECT_MOODY"] else { return }
        let resources = try LibronCatalog.load(from:URL(fileURLWithPath:path)).resources
        let resource = try #require(resources.first { $0.location.lastPathComponent == "MHNDTHEO.lbxlls" })
        let inner = try await LibronixBookService.shared.prepare(resource)
        let index = try LegacyContentReader.inspectSections(lsfURL:inner.location)
        let descriptor = index.sections[1668]
        let page = try await ReaderSession.readOriginal(resource,.init(ordinal:1668))
        #expect(page.text.hasSuffix("317"))
        #expect(page.content?.warnings.contains(where: { $0.hasPrefix("Recovered malformed closing reference metadata:") }) == true)
        let data = try LegacyContentReader.decodedSectionPayload(lsfURL:inner.location,ordinal:1668)
        let offset = 882874 - Int(descriptor.payloadOffset)
        print("Moody section 1668: stored=\(descriptor.storedLength) decoded=\(descriptor.decodedLength) relativeFailure=\(offset)")
        print("Header: \(data.prefix(48).map { String(format:"%02x",$0) }.joined())")
        if offset >= 0, offset <= data.count {
            print("Structure context: \(data[max(0,offset-60)..<min(data.count,offset+60)].map { String(format:"%02x",$0) }.joined())")
        }
    }

}
