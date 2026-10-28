import Foundation
import Testing
import CSQLite
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct PassageGuideControllerTests {
    @Test func realCommentaryAndExplicitReferencesRetainTheirSource() async throws {
        let (root, workspace) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("owned.cmti")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = "CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Owned Commentary','OWN','Owned fixture'); CREATE TABLE BookCommentary(Book,Comments); CREATE TABLE ChapterCommentary(Book,Chapter,Comments); CREATE TABLE VerseCommentary(Book,ChapterBegin,VerseBegin,ChapterEnd,VerseEnd,Comments); INSERT INTO VerseCommentary VALUES(1,1,1,1,1,'Owned note citing Ge 1:1');"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK); sqlite3_close(db)
        let resource = try ESwordResource.inspect(url); workspace.resources = [resource]
        let controller = PassageGuideController(referenceLookup: { resources, query in
            let report = try await BibleReferenceSearchService(provider: WorkspaceSearchReader()).search(resources: resources, query: query)
            return .init(results: report.results, complete: report.coverageComplete, warnings: [])
        })
        controller.passage = "Ge 1:1"; controller.run(workspace: workspace); try await wait(controller)
        #expect(controller.completed && controller.error == nil)
        #expect(controller.matches.count == 1 && controller.matches[0].match.resource == resource)
        #expect(controller.matches[0].match.page.text.contains("Owned note"))
        #expect(controller.references?.results.contains { $0.sourceTitle == resource.title && $0.resourceDestination != nil } == true)
    }
    private func fixture() throws -> (URL, StudyWorkspace) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = StudyWorkspace(personal: .init(url: root.appendingPathComponent("personal.json")),
            resourceVisibility: .init(url: root.appendingPathComponent("visibility.json")),
            resourcePriorities: .init(url: root.appendingPathComponent("priorities.json")))
        func resource(_ name: String, _ type: String) -> LibraryResource {
            var metadata = LibronMetadata(title: name, origin: "Owned fixture"); metadata.resourceType = type
            return .init(location: root.appendingPathComponent(name), title: name, byteCount: 0,
                format: .legacyLSF, support: .metadataOnly, provenance: .fileName, libron: metadata)
        }
        workspace.resources = [resource("Commentary", "Comentario bíblico"), resource("Dictionary", "Diccionario o enciclopedia"), resource("Lexicon", "Léxico")]
        return (root, workspace)
    }
    private func wait(_ controller: PassageGuideController) async throws {
        for _ in 0..<500 where controller.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isLoading)
    }
    @Test func guideCombinesSourcesPreservesTermsAndReportsIncompleteCoverage() async throws {
        let (root, workspace) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = PassageGuideController(lookup: { resource, scope, term in
            if scope.kind == .lexicon { throw RebuildError.unsupportedFormat }
            return .init(resource: resource, destination: .init(ordinal: 0), label: term,
                page: .init(destination: .init(ordinal: 0), text: "Owned source", sectionCount: 1), stamps: [])
        }, referenceLookup: { resources, _ in
            .init(results: [], complete: false, warnings: ["Partial: \(resources.count)"])
        })
        controller.passage = "Ge 1:1"; controller.terms = "Light, light; water"
        controller.run(workspace: workspace); try await wait(controller)
        #expect(controller.completed && controller.error == nil)
        #expect(controller.searchedTerms == ["Light", "water"])
        #expect(controller.commentaryCount == 1 && controller.dictionaryCount == 2)
        #expect(controller.matches.filter { $0.kind == .commentary }.count == 1)
        #expect(controller.matches.filter { $0.kind == .dictionary }.map(\.term) == ["Light", "water"])
        #expect(controller.failures.count == 2 && controller.references?.complete == false)
    }
    @Test func invalidQueriesAndCancellationNeverPublishLateResults() async throws {
        let (root, workspace) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = PassageGuideController(lookup: { resource, _, query in
            try? await Task.sleep(for: .milliseconds(100))
            return .init(resource: resource, destination: .init(ordinal: 0), label: query,
                page: .init(destination: .init(ordinal: 0), text: "Owned", sectionCount: 1), stamps: [])
        }, referenceLookup: { _, _ in .init(results: [], complete: true, warnings: []) })
        controller.passage = "not a passage"; controller.run(workspace: workspace)
        #expect(controller.error != nil && !controller.isLoading)
        controller.passage = "Ge 1:1"; controller.terms = Array(repeating: "word", count: 9).joined(separator: ",")
        controller.run(workspace: workspace); #expect(controller.error != nil && !controller.isLoading)
        controller.terms = "word"; controller.run(workspace: workspace); await Task.yield(); controller.clear()
        try await Task.sleep(for: .milliseconds(180))
        #expect(!controller.completed && !controller.isLoading && controller.matches.isEmpty && controller.references == nil)
    }
    @Test func commentaryIsAvailableWhileReferencesAreStillSearching() async throws {
        let (root, workspace) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = PassageGuideController(lookup: { resource, _, query in
            .init(resource: resource, destination: .init(ordinal: 0), label: query,
                page: .init(destination: .init(ordinal: 0), text: "Owned", sectionCount: 1), stamps: [])
        }, referenceLookup: { _, _ in
            try await Task.sleep(for: .milliseconds(300))
            return .init(results: [], complete: true, warnings: [])
        })
        controller.passage = "Ge 1:1"; controller.run(workspace: workspace)
        for _ in 0..<100 where controller.matches.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.isLoading && !controller.completed && controller.matches.count == 1)
        #expect(controller.matches[0].kind == .commentary && controller.references == nil)
        controller.clear(); #expect(!controller.isLoading && controller.matches.isEmpty)
    }
}
