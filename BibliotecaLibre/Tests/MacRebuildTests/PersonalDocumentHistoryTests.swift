import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct PersonalDocumentHistoryTests {
    @Test func revisionsSurviveRotationAndRecoverAsIndependentCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json"), state = WorkspacePersonalState(url: url)
        var original = StudyDocument(title: "Revision 1", kind: .notebook); original.schemaVersion = 2
        let parent = StudyNote(title: "Parent")
        var child = StudyNote(title: "Child"); child.parentID = parent.id; child.sourceBody = "First body"
        original.notes = [parent, child]
        state.documents = [original]; try state.save()
        state.documents[0].title = "Revision 2"; try state.save()
        state.documents[0].title = "Revision 3"; state.documents[0].notes[1].sourceBody = "Latest body"; try state.save()
        let reloaded = WorkspacePersonalState(url: url)
        let history = try reloaded.documentHistory()
        #expect(Set(history.versions.map { $0.document.title }) == ["Revision 1", "Revision 2"])
        #expect(history.unreadableSnapshots == 0 && !history.hasMore)
        let first = try #require(history.versions.first { $0.document.title == "Revision 1" })
        let count = history.versions.count
        try reloaded.save()
        #expect(try reloaded.documentHistory().versions.count == count)
        try reloaded.recoverDocumentVersion(first, title: "Recovered")
        #expect(reloaded.documents[0].title == "Revision 3" && reloaded.documents[0].notes[1].sourceBody == "Latest body")
        let copy = try #require(reloaded.documents.last)
        #expect(copy.title == "Recovered" && copy.id != original.id)
        #expect(copy.notes[1].sourceBody == "First body" && copy.notes[1].parentID == copy.notes[0].id)
        #expect(copy.notes[0].id != parent.id && copy.notes[0].origin?.documentID == original.id)
        #expect(try PersonalDocumentHistory.verify(first).isEmpty == false)
        #expect(try reloaded.documentHistory().versions.contains { $0.document.title == "Revision 3" })
    }
    @Test func failedArchivesAndConcurrentWritesNeverRotateTheLiveData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json"), state = WorkspacePersonalState(url: url)
        state.documents = [StudyDocument(title: "Original", kind: .verseList)]; try state.save()
        let original = try Data(contentsOf: url)
        let history = root.appendingPathComponent("personal-history")
        try Data("blocked".utf8).write(to: history)
        state.documents[0].title = "Edited"
        #expect(throws: (any Error).self) { try state.save() }
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("previous").path))
        try FileManager.default.removeItem(at: history)
        let external = Data("changed outside".utf8); try external.write(to: url)
        #expect(throws: (any Error).self) { try state.save() }
        #expect(try Data(contentsOf: url) == external)
        #expect(!FileManager.default.fileExists(atPath: history.path))
    }
    @Test func corruptVersionsStayOnDiskAndChangedRecoverySourcesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json"), state = WorkspacePersonalState(url: url)
        state.documents = [StudyDocument(title: "Before", kind: .verseList)]; try state.save()
        state.documents[0].title = "After"; try state.save()
        let badURL = root.appendingPathComponent("personal-history/broken.json"), bad = Data("broken".utf8)
        try bad.write(to: badURL)
        let history = try state.documentHistory()
        #expect(history.unreadableSnapshots == 1 && history.versions.count == 1)
        #expect(try Data(contentsOf: badURL) == bad)
        let version = try #require(history.versions.first)
        try bad.write(to: version.source)
        #expect(throws: (any Error).self) { try state.recoverDocumentVersion(version, title: "Must fail") }
        #expect(state.documents.count == 1 && state.documents[0].title == "After")
    }
    @Test func paginationExposesOlderSnapshotsWithoutDeletingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json"), state = WorkspacePersonalState(url: url)
        state.documents = [StudyDocument(title: "0", kind: .verseList)]; try state.save()
        for index in 1...25 { state.documents[0].title = String(index); try state.save() }
        let first = try state.documentHistory(), second = try state.documentHistory(offset: 20)
        #expect(first.hasMore && !second.hasMore)
        #expect(Set((first.versions + second.versions).map { $0.document.title }) == Set((0..<25).map(String.init)))
        let archives = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("personal-history").path)
        #expect(archives.count == 25)
    }
}
