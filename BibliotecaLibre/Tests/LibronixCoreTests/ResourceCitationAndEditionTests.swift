import Foundation
import Testing
@testable import LibronixCore

struct ResourceCitationAndEditionTests {
    func resource(_ root: URL, _ name: String, bytes: String, year: String? = "2001", edition: String? = nil) throws -> LibraryResource {
        let url = root.appendingPathComponent(name + ".lsf");try Data(bytes.utf8).write(to:url)
        var metadata = LibronMetadata(title:"Authored Book",origin:"Fixture");metadata.authors=["Smith, Jane"];metadata.year=year;metadata.publisher="Owned Press";metadata.edition=edition
        return .init(location:url,title:metadata.title,byteCount:Int64(bytes.utf8.count),format:.legacyLSF,support:.metadataOnly,provenance:.libronixMetadata,libron:metadata)
    }
    @Test func bookStylesUseOneEditionSnapshotAndNeverInventMissingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        let resource = try resource(root,"one",bytes:"source",edition:"Second edition")
        let entry = try BibliographyReportGenerator.generate(resources:[resource],scope:.init(kind:.selection,names:[],requestedCount:1)).entries[0]
        #expect(ResourceCitation.text(entry,style:.chicagoAuthorDate) == "Smith, Jane. 2001. Authored Book. Second edition. Owned Press.")
        #expect(ResourceCitation.text(entry,style:.mla) == "Smith, Jane. Authored Book. Second edition, Owned Press, 2001.")
        #expect(ResourceCitation.html(entry,style:.mla).contains("<i>Authored Book</i>"))
        let missing = try self.resource(root,"missing",bytes:"other",year:nil)
        let unknown = try BibliographyReportGenerator.generate(resources:[missing],scope:.init(kind:.selection,names:[],requestedCount:1)).entries[0]
        #expect(ResourceCitation.text(unknown,style:.chicagoAuthorDate).contains("n.d."))
        #expect(!ResourceCitation.text(unknown,style:.mla).contains("2001"))
        #expect(unknown.field(.year).certainty == .unknown && unknown.field(.edition).values.isEmpty)
    }
    @Test func hashesSeparateExactCopiesDistinctEditionsAndUnreadableInputs() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        let a=try resource(root,"a",bytes:"same"),b=try resource(root,"b",bytes:"same"),c=try resource(root,"c",bytes:"different",year:"2008",edition:"Revised")
        let result=try LibraryEditionAudit.scan([a,b,c])
        #expect(result.examined == 3 && result.issues.isEmpty)
        #expect(result.groups.first { $0.kind == .exactCopies }?.resources.map(\.id) == [a.id,b.id])
        #expect(result.groups.first { $0.kind == .possibleEditions }?.resources.count == 3)
        #expect(result.groups.filter { $0.kind == .exactCopies }.allSatisfy { !$0.resources.contains(c) })
        try FileManager.default.removeItem(at:b.location)
        let changed=try LibraryEditionAudit.scan([a,b,c])
        #expect(changed.examined == 2 && changed.issues.count == 1 && !changed.groups.contains { $0.kind == .exactCopies })
        #expect(try Data(contentsOf:a.location) == Data("same".utf8))
    }
    @Test func identicalSourcesWithDifferentNativeRepresentationsAreReviewOnly() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        var inputs:[LibraryResource]=[]
        for index in 0..<2 {
            let r=try resource(root,"source\(index)",bytes:"identical source")
            let package=try LibronPackage.create(r,in:root.appendingPathComponent("library\(index)"),backup:false)
            let normalized=package.appendingPathComponent("normalized");try FileManager.default.createDirectory(at:normalized,withIntermediateDirectories:true)
            try Data("authored reader \(index)".utf8).write(to:normalized.appendingPathComponent("reader.sqlite"))
            try LibronPackage.registerNormalizedContent(in:package)
            inputs.append(try LibronPackage.read(package).1)
        }
        let audit=try LibraryEditionAudit.scan(inputs)
        #expect(audit.issues.isEmpty && audit.groups.contains { $0.kind == .differentReaders })
        #expect(!audit.groups.contains { $0.kind == .exactCopies })
    }
}
