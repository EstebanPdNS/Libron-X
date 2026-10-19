import Foundation
import Testing
import CSQLite
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct StandaloneCommentaryTests {
    private func resource(_ root: URL, name: String, commentary: Bool) async throws -> LibraryResource {
        let source = root.appendingPathComponent(name + (commentary ? ".cmti" : ".bbli"))
        var db: OpaquePointer?
        #expect(sqlite3_open(source.path, &db) == SQLITE_OK)
        let sql = commentary ? """
        CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Independent commentary','C','Authored fixture');
        CREATE TABLE BookCommentary(Book,Comments); CREATE TABLE ChapterCommentary(Book,Chapter,Comments);
        CREATE TABLE VerseCommentary(Book,ChapterBegin,VerseBegin,ChapterEnd,VerseEnd,Comments);
        INSERT INTO VerseCommentary VALUES(1,1,1,1,3,'Broad source note.'),(1,1,2,1,2,'Specific source note.'),(1,2,1,2,2,'Next chapter note.');
        """ : """
        CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Authored Bible','B','Authored fixture');
        CREATE TABLE Bible(Book,Chapter,Verse,Scripture);
        INSERT INTO Bible VALUES(1,1,1,'Verse one.'),(1,1,2,'Verse two.'),(1,1,4,'Verse four.'),(1,2,1,'Next chapter.');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK); sqlite3_close(db)
        let package = try LibronPackage.create(ESwordResource.inspect(source), in: root.appendingPathComponent("Library"), backup: false)
        let result = try LibronPackage.read(package).1
        _ = try await LibronNativeNormalizer.shared.convert(result)
        return try LibronPackage.read(package, verify: true).1
    }
    private func settle(_ reader: ReaderSession) async throws {
        for _ in 0..<1000 {
            if !reader.isLoading { return }; try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Commentary did not settle")
    }
    @Test func independentRangesKeepWholeChaptersSpecificCoverageAndGaps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let commentary = try await resource(root, name: "commentary", commentary: true)
        let page = try await ReaderSession.read(commentary, .init(ordinal: 0, reference: "Ge 1:2", commentaryChapter: "ge 1:1"))
        #expect(page.text.contains("Broad source note.") && page.text.contains("Specific source note."))
        #expect(page.commentaryLocations["ge 1:1"] != page.commentaryLocations["ge 1:2"])
        #expect(page.commentaryLocations["ge 1:3"] == page.commentaryLocations["ge 1:1"])
        #expect(page.commentaryLocations["ge 1:4"] == nil)
        let second = try await ReaderSession.read(commentary, .init(ordinal: 0, reference: "Ge 2:1", commentaryChapter: "ge 2:1"))
        #expect(second.text.contains("Next chapter note.") && !second.text.contains("Broad source note."))
        #expect(second.commentaryLocations["ge 2:3"] == nil)
    }
    @Test func aDifferentBibleDrivesTheCommentaryAndPauseAndWorkspaceRestoreRetainTheRelationship() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bible = try await resource(root, name: "bible", commentary: false)
        let commentary = try await resource(root, name: "commentary", commentary: true)
        let workspace = StudyWorkspace(); workspace.resources = [bible, commentary]
        let source = workspace.open(bible, destination: .init(ordinal: 0, reference: "Ge 1:1")); try await settle(source)
        workspace.openCommentary(commentary)
        let target = try #require(workspace.activeReader); try await settle(target)
        #expect(target.isCommentary && target.resource.id != source.resource.id && target.commentarySourceID == source.id)
        source.followBibleReference("Ge 1:2"); try await settle(source); try await settle(target)
        #expect(target.commentaryReference == "Ge 1:2" && target.page?.text.contains("Specific source note.") == true)
        workspace.setCommentaryFollowing(false, for: target)
        source.followBibleReference("Ge 2:1"); try await settle(source); try await settle(target)
        #expect(target.commentaryReference == "Ge 1:2")
        workspace.setCommentaryFollowing(true, for: target); try await settle(target)
        #expect(target.commentaryReference == "Ge 2:1" && target.page?.text.contains("Next chapter note.") == true)
        let saved = workspace.archive(); try saved.validate()
        let restored = StudyWorkspace(); try restored.restore(saved)
        let follower = try #require(restored.readers.first(where: { $0.isCommentary }))
        #expect(follower.commentarySourceID != nil && follower.commentaryFollowsActiveBible)
        let other = workspace.open(bible, destination: .init(ordinal: 0, reference: "Ge 1:1")); try await settle(other)
        workspace.activate(other); try await settle(target)
        #expect(target.commentarySourceID == other.id && target.commentaryReference == "Ge 1:1")
        workspace.chooseCommentarySource(nil, for: target, activeBible: true); try await settle(target)
        #expect(target.commentarySourceID == other.id)
        workspace.close(other); try await settle(target)
        #expect(target.commentarySourceID == source.id && target.commentaryReference == "Ge 2:1")
        workspace.closeAll(); restored.closeAll()
    }
    @Test func deletingAnAutomaticLanguageGroupPersistsWithoutTouchingBooksOrCustomGroups() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Source"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("groups.json"), store = ParallelBibleSets(url: url)
        let id = try store.create(); try store.add(fixture.resources[0], to: id)
        let before = try Data(contentsOf: fixture.resources[0].location)
        try store.excludeAutomaticLanguage("es"); try store.excludeAutomaticLanguage("es")
        let restored = ParallelBibleSets(url: url)
        #expect(restored.excludedAutomaticLanguages == ["es"] && restored.sets == store.sets)
        try restored.restoreAutomaticLanguages()
        #expect(ParallelBibleSets(url: url).excludedAutomaticLanguages.isEmpty)
        #expect(try Data(contentsOf: fixture.resources[0].location) == before)
    }
    @Test func stagedPublicAndOwnedCommentariesRetainNativeChapterTextLinksAndIllustrations() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_STANDALONE_CORPUS"] else { return }
        let root = URL(fileURLWithPath: path)
        var count = 0
        for directory in ["staged-public", "staged-nelson"] {
            let catalog = try LibronCatalog.load(from: root.appendingPathComponent(directory))
            for resource in catalog.resources {
                print("Checking independent commentary: \(resource.title)")
                let index = try await LibronNativeReader.shared.standaloneIndex(resource)
                #expect(!index.isEmpty)
                for reference in [index.first?.start, "Ge 1:1", "Da 3:25", "Jn 3:16", "Re 22:21"].compactMap({ $0 }) {
                    let query = try #require(LegacyPassageQuery.sourceReference(reference))
                    guard index.contains(where: { LegacyPassageQuery.sourceReference($0.start)?.normalizedKey == query.normalizedKey }) else { continue }
                    let chapter = "\(query.sourceBookKey) \(query.chapter):1"
                    let page = try await ReaderSession.read(resource, .init(ordinal: 0, reference: reference, commentaryChapter: chapter))
                    #expect(!page.text.isEmpty && page.commentaryLocations[query.normalizedKey] != nil)
                    #expect(page.inlineLinks.allSatisfy { Range($0.range, in: page.text) != nil })
                    if resource.title.hasPrefix("Thomas Nelson"), query.normalizedKey == "da 3:25" {
                        #expect(page.text.contains("Theophanies") && !page.graphics.isEmpty)
                    }
                }
                count += 1
            }
        }
        #expect(count == 6)
    }

}
