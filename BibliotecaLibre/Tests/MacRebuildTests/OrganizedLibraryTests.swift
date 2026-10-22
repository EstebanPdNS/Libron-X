import Foundation
import AppKit
import Testing
import CSQLite
import LibronixCore
@testable import MacRebuild

@MainActor struct OrganizedLibraryTests {
    private func settle(_ reader: ReaderSession) async throws {
        for _ in 0..<2000 where reader.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!reader.isLoading && reader.error == nil)
    }
    @Test func strongToggleKeepsTheBibleIdentityPassageAndSavedWorkspaceMode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func bible(_ name: String, text: String) async throws -> LibraryResource {
            let source = root.appendingPathComponent(name + ".bbli")
            var db: OpaquePointer?; #expect(sqlite3_open(source.path, &db) == SQLITE_OK)
            let sql = "CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('\(name)','T','Authored fixture'); CREATE TABLE Bible(Book,Chapter,Verse,Scripture); INSERT INTO Bible VALUES(1,1,1,'\(text)'),(1,1,2,'Second verse');"
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK); sqlite3_close(db)
            let package = try LibronPackage.create(ESwordResource.inspect(source), in: root.appendingPathComponent("Library"), backup: false)
            let resource = try LibronPackage.read(package).1
            _ = try await LibronNativeNormalizer.shared.convert(resource)
            return try LibronPackage.read(package, verify: true).1
        }
        let base = try await bible("Plain Bible", text: "In the beginning"), strong = try await bible("Annotated Bible", text: "In the beginning H7225")
        let package = try #require(base.packageLocation), variant = try #require(strong.packageLocation)
        var manifest = try LibronPackage.read(package).0
        manifest.metadata.evidence.append(.init(field: "strongVariantPackage", value: variant.path, source: "Authored fixture"))
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let edition = try LibronPackage.read(package, verify: true).1
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: root.appendingPathComponent("personal.json")))
        workspace.resources = [edition, strong]
        let reader = workspace.open(edition, destination: .init(ordinal: 0, reference: "Ge 1:1"))
        try await settle(reader)
        #expect(reader.page?.text.contains("H7225") == false)
        reader.toggleStrongNumbers(); try await settle(reader)
        #expect(reader.showsStrongNumbers && reader.resource.id == edition.id && reader.page?.text.contains("H7225") == true)
        #expect(reader.currentReference == "Ge 1:1")
        let archive = workspace.archive(); try archive.validate()
        #expect(archive.panes.first?.strongNumbers == true)
        let restored = StudyWorkspace(personal: WorkspacePersonalState(url: root.appendingPathComponent("restored-personal.json")))
        try restored.restore(archive)
        let restoredReader = try #require(restored.readers.first)
        try await settle(restoredReader)
        #expect(restoredReader.showsStrongNumbers && restoredReader.resource.id == edition.id && restoredReader.page?.text.contains("H7225") == true)
        restored.closeAll()
        reader.toggleStrongNumbers(); try await settle(reader)
        #expect(!reader.showsStrongNumbers && reader.page?.text.contains("H7225") == false && reader.currentReference == "Ge 1:1")
        reader.toggleStrongNumbers(); try await settle(reader)
        let other = try await bible("Other Bible", text: "A different translation")
        reader.changeBibleVersion(to: other, reference: "Ge 1:1"); try await settle(reader)
        #expect(!reader.showsStrongNumbers && reader.readingResource.id == other.id && reader.page?.text.contains("A different translation") == true)
        workspace.closeAll()
    }
    @Test func coverageRejectsGapsOtherBooksAndUnindexedCitations() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Comment on Genesis 1:1–3"], ["A citation of Genesis 1:4"]])
        defer { fixture.remove() }
        var resources: [LibraryResource] = []
        for (i, source) in fixture.resources.enumerated() {
            var metadata = LibronMetadata(title: "Commentary \(i)", origin: "Authored fixture")
            metadata.resourceType = "Comentario bíblico"
            let package = try LibronPackage.create(source, in: fixture.root.appendingPathComponent("Library"), backup: false, metadata: metadata)
            let resource = try LibronPackage.read(package).1
            _ = try await LibronNativeNormalizer.shared.convert(resource)
            if i == 0 {
                let db = try LibronNativeDatabase(try #require(LibronNativeReader.location(resource)), edit: true)
                try db.put("commentary-index", data: JSONEncoder().encode([StandaloneCommentaryEntry(start: "Ge 1:1", end: "Ge 1:3", ordinal: 0, offset: 0)]))
                try db.finish(); try LibronPackage.registerNormalizedContent(in: package)
            }
            resources.append(resource)
        }
        let catalog = CommentaryCoverageCatalog()
        #expect(try await catalog.matching(resources, reference: "Ge 1:2") == [resources[0].id])
        #expect(try await catalog.matching(resources, reference: "Ge 1:4").isEmpty)
        #expect(try await catalog.matching(resources, reference: "Jn 1:2").isEmpty)
        #expect(try await catalog.matching(resources, reference: "Ge 2:1").isEmpty)
    }
    @Test func installedCollectionsAndStrongModesReadRealNativeContent() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_ORGANIZED_CORPUS"] else { return }
        let resources = try LibronCatalog.load(from: URL(fileURLWithPath: path)).resources
        let catalog = CommentaryCoverageCatalog()
        let collectionNames = ["Comentario bíblico del Continente Nuevo", "Comentario bíblico Mundo Hispano", "Comentario exegético y explicativo de la Biblia"]
        for title in collectionNames {
            let resource = try #require(resources.first { $0.title == title })
            _ = try LibronPackage.read(try #require(resource.packageLocation), verify: true)
            let index = try await LibronNativeReader.shared.standaloneIndex(resource)
            #expect(!index.isEmpty)
            for entry in [index.first!, index.last!] {
                let query = try #require(LegacyPassageQuery.sourceReference(entry.start))
                let page = try await ReaderSession.read(resource, .init(ordinal: 0, reference: entry.start, commentaryChapter: "\(query.sourceBookKey) \(query.chapter):1"))
                #expect(!page.text.isEmpty && page.commentaryLocations[query.normalizedKey] != nil)
                #expect(page.inlineLinks.allSatisfy { Range($0.range, in: page.text) != nil })
            }
        }
        let compatible = try await catalog.matching(resources.filter { $0.libron?.resourceType == "Comentario bíblico" }, reference: "Ho 2:16")
        #expect(!compatible.contains(resources.first { $0.title == collectionNames[0] }!.id))
        #expect(compatible.contains(resources.first { $0.title == collectionNames[1] }!.id))
        let exegesis = try #require(resources.first { $0.title == collectionNames[2] })
        for reference in ["Ge 1:1", "Ps 23:1", "Isa 53:1", "Da 6:13", "Ac 2:1", "1Ti 6:1", "Re 22:21"] {
            #expect(try await catalog.matching([exegesis], reference: reference) == [exegesis.id], "Missing \(reference)")
        }
        for resource in resources where resource.libron?.evidence.contains(where: { $0.field == "strongVariantPackage" }) == true {
            let reader = ReaderSession(resource: resource)
            let reference = resource.title.hasPrefix("Textus") ? "Jn 3:16" : "Ge 1:1"
            reader.load(.init(ordinal: 0, reference: reference)); try await settle(reader)
            #expect(reader.page?.text.range(of: "[HG][0-9]+", options: .regularExpression) == nil)
            reader.toggleStrongNumbers(); try await settle(reader)
            #expect(reader.page?.text.range(of: "[HG][0-9]+", options: .regularExpression) != nil)
            #expect(reader.resource.id == resource.id)
            let page = try #require(reader.page), rtf = try #require(page.content?.richTextRTF)
            let styled = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            #expect(styled.string == page.text)
            let number = (page.text as NSString).range(of: "[HG][0-9]+", options: .regularExpression)
            let bodyFont = try #require(styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            let numberFont = try #require(styled.attribute(.font, at: number.location, effectiveRange: nil) as? NSFont)
            #expect(numberFont.pointSize < bodyFont.pointSize)
            if resource.title == "Reina-Valera 1960" {
                #expect(reader.page?.text.range(of: #"\b(?:NCc[A-Za-z0-9-]+|Vq[A-Za-z0-9-]+)\b"#, options: .regularExpression) == nil)
            }
            reader.cancel()
        }
    }
}
