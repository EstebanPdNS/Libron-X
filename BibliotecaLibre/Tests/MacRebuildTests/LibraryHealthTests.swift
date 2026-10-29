import Foundation
import CSQLite
import LibronixCore
import Testing
@testable import MacRebuild

struct LibraryHealthTests {
    @Test func reportsOnlyVerifiedProblemsAndKeepsEditionIdentity() {
        let good = LibraryResource(location: URL(fileURLWithPath: "/fixture/good"), title: "Good", byteCount: 1,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName, legacyIdentifier: "a", stableID: "good")
        let broken = LibraryResource(location: URL(fileURLWithPath: "/fixture/missing"), title: "Broken", byteCount: 1,
            format: .legacyLSF, support: .invalidFile, provenance: .fileName, warnings: ["warning"], stableID: "bad")
        let missing = ReaderLocation(resourceID: "good", legacyIdentifier: "different edition", format: .legacyLSF, sectionOrdinal: 0)
        var document = StudyDocument(title: "Notes", kind: .notebook)
        document.notes = [StudyNote(title: "Missing edition", anchor: .init(kind: .nativeSelection, location: missing)),
                          StudyNote(title: "Legacy", anchor: .init(kind: .legacySelection))]
        let mark = ReaderHighlight(resourceID: "unknown", ordinal: 0, fingerprint: "fixture", range: .init(location: 0, length: 1), color: "yellow")
        let report = LibraryHealthReport.inspect(resources: [good, broken], documents: [document], highlights: [mark], exists: { $0.path == "/fixture/good" })
        #expect(report.resourceCount == 2 && report.omittedIssueCount == 0)
        #expect(report.issues.filter { $0.kind == .missingResource }.count == 1)
        #expect(report.issues.filter { $0.kind == .invalidResource }.count == 1)
        #expect(report.issues.filter { $0.kind == .resourceWarning }.count == 1)
        #expect(report.issues.filter { $0.kind == .missingAnnotationSource }.count == 2)
        #expect(report.issues.filter { $0.kind == .unresolvedAnnotation }.count == 1)
        #expect(Set(report.issues.map(\.id)).count == report.issues.count)
    }
    @Test func capsOutputAndAccountsForOmittedIssues() {
        let items = (0..<5002).map { index in
            LibraryResource(location: URL(fileURLWithPath: "/fixture/\(index)"), title: "Resource", byteCount: 0,
                            format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        }
        let report = LibraryHealthReport.inspect(resources: items, documents: [], highlights: [], exists: { _ in false })
        #expect(report.issues.count == 5000 && report.omittedIssueCount == 2)
    }
    @Test func findsMissingDeclaredIndexAndIncompleteConversion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("normalized"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.lsf"), index = folder.appendingPathComponent("source.lix")
        try Data().write(to: source)
        let receipt = LibronNormalizationReceipt(resourceID: "owned", sourceSHA256: "owned", state: "pending", profile: "", sections: 1, checkedSections: 0, warnings: [])
        try JSONEncoder().encode(receipt).write(to: folder.appendingPathComponent("normalized/conversion.json"))
        let resource = LibraryResource(location: source, indexLocation: index, title: "Owned", byteCount: 0, format: .legacyLSF, support: .metadataOnly, provenance: .fileName, packageLocation: folder)
        let report = LibraryHealthReport.inspect(resources: [resource], documents: [], highlights: [])
        #expect(report.issues.contains { $0.kind == .missingResource && $0.detail == index.path })
        #expect(report.issues.contains { $0.kind == .conversionIssue })
    }

    @Test func reportsUnavailableFavoritesAndBookmarksWithoutChangingThem() {
        let location = ReaderLocation(resourceID: "missing", format: .legacyLSF, sectionOrdinal: 1)
        let favorite = LibraryFavorite(title: "Owned favorite", kind: .location, location: location)
        let original = LibraryFavorite(title: "Unknown command", kind: .legacyCommand, legacyCommand: "unrecognized")
        let report = LibraryHealthReport.inspect(resources: [], documents: [], highlights: [], favorites: [favorite, original], bookmarks: [2: location])
        #expect(report.issues.filter { $0.kind == .unresolvedLink }.count == 3)
        #expect(original.legacyCommand == "unrecognized" && favorite.location == location)
    }

    @Test func distinguishesAbsentHealthyAndDamagedSearchCaches() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let resource = LibraryResource(location: folder.appendingPathComponent("book"), title: "Owned", byteCount: 0, format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        #expect(LibrarySearchIndexHealth.inspect(resource: resource, directory: folder) == .absent)
        let url = folder.appendingPathComponent(PersistentLibrarySearchProvider.filename(for: resource))
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version=2;CREATE TABLE identity(value);CREATE TABLE articles(ordinal);CREATE TABLE terms(value);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(LibrarySearchIndexHealth.inspect(resource: resource, directory: folder) == .healthy)
        try Data("corrupt".utf8).write(to: url)
        #expect(LibrarySearchIndexHealth.inspect(resource: resource, directory: folder) == .damaged)
        let report = LibraryHealthReport.inspect(resources: [resource], documents: [], highlights: [], indexDirectory: folder)
        #expect(report.issues.contains { $0.kind == .damagedIndex })
    }

    @Test func checksTheConvertedDatabaseSchemaAndIntegrity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("reader.sqlite")
        #expect(LibrarySearchIndexHealth.inspectNormalized(at: url) == .absent)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version=1;CREATE TABLE values_v1(key);CREATE TABLE bible_v1(book);CREATE TABLE words_v1(key);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(LibrarySearchIndexHealth.inspectNormalized(at: url) == .healthy)
        try Data("corrupt".utf8).write(to: url)
        #expect(LibrarySearchIndexHealth.inspectNormalized(at: url) == .damaged)
    }

    @Test func reportsMissingVerseListDestinations() {
        let missing = ReaderLocation(resourceID: "missing-edition", format: .legacyLSF, sectionOrdinal: 0)
        var document = StudyDocument(title: "Owned list", kind: .verseList)
        document.verses = [StudyVerseEntry(reference: "John 3:16", location: missing)]
        let report = LibraryHealthReport.inspect(resources: [], documents: [document], highlights: [])
        #expect(report.issues.contains { $0.kind == .unresolvedLink && $0.title == "John 3:16" })
    }

    @Test func reportsMissingEditionsInPlansAndMemoryCards() {
        let resource = LibraryResource(location: URL(fileURLWithPath: "/owned/bible"), title: "Edition", byteCount: 0, format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        let edition = StudyBibleEdition(resource)
        let plan = ReadingPlan(title: "Owned plan", readings: [], edition: edition)
        let card = ScriptureMemoryCard(reference: "John 3:16", passage: "Owned text", sourceEdition: edition)
        let location = ReaderLocation(resourceID: resource.id, format: resource.format, sectionOrdinal: 0)
        let excerpt = ResearchExcerpt(sourceTitle: "Owned excerpt", text: "Text", location: location, selectionLength: 4)
        let report = LibraryHealthReport.inspect(resources: [], documents: [], highlights: [], plans: [plan], memoryCards: [card], excerpts: [excerpt])
        #expect(report.issues.filter { $0.kind == .unresolvedLink }.count == 3)
    }

    @Test func reportsMissingCollectionAndAssociationMembers() {
        let resource = LibraryResource(location: URL(fileURLWithPath: "/owned/missing"), title: "Owned Bible", byteCount: 0, format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        let member = LibraryCollectionMember(resource)
        let collection = LibraryCollection(name: "Owned collection", members: [member])
        let association = ResourceAssociationSet(name: "Owned association", members: [member])
        let report = LibraryHealthReport.inspect(resources: [], documents: [], highlights: [], collections: [collection], associations: [association])
        #expect(report.issues.filter { $0.kind == .unresolvedLink }.count == 2)
    }

}
