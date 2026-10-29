import Foundation
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

}
