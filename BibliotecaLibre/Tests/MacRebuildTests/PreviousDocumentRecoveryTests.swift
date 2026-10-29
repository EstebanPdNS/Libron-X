import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@Suite(.serialized) @MainActor struct PreviousDocumentRecoveryTests {
    @Test func recoveredCopyPreservesHierarchyAndLeavesCurrentDocumentUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = WorkspacePersonalState(url: directory.appendingPathComponent("personal.json"))
        var document = StudyDocument(title: "Original", kind: .notebook); document.schemaVersion = 2
        let parent = StudyNote(title: "Parent")
        var child = StudyNote(title: "Child"); child.parentID = parent.id
        document.notes = [parent, child]
        state.documents = [document]; try state.save()
        state.documents[0].title = "Current"; try state.save()
        let prior = try #require(state.previousDocuments().first)
        try state.save()
        #expect(try state.previousDocuments().first == prior)
        try state.recoverPreviousDocument(prior, title: "Recovered")
        #expect(state.documents.count == 2 && state.documents[0].title == "Current")
        let copy = state.documents[1]
        #expect(copy.id != document.id && copy.notes[0].id != parent.id)
        #expect(copy.notes[1].parentID == copy.notes[0].id)
        #expect(copy.notes[0].origin?.documentID == document.id)
        #expect(state.selectedDocumentID == copy.id)
        let archives = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("personal-recovery"), includingPropertiesForKeys: nil)
        #expect(archives.count == 1)
        let archived = try JSONDecoder().decode(WorkspacePersonalSnapshot.self, from: Data(contentsOf: try #require(archives.first)))
        #expect(archived.documents == [prior])
        #expect(throws: (any Error).self) { try state.recoverPreviousDocument(prior, title: "Stale") }
    }
    @Test func missingAndInvalidBackupsAreNotReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("personal.json")
        #expect(try PreviousDocumentRecovery.read(from: url).isEmpty)
        let backup = url.appendingPathExtension("previous"), invalid = Data("invalid".utf8)
        try invalid.write(to: backup)
        #expect(throws: (any Error).self) { try PreviousDocumentRecovery.read(from: url) }
        #expect(try Data(contentsOf: backup) == invalid)
    }
    @Test func aSaveConflictKeepsTheRecoverySource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("personal.json"), state = WorkspacePersonalState(url: url)
        let original = StudyDocument(title: "Previous", kind: .notebook)
        state.documents = [original]; try state.save()
        state.documents[0].title = "Current"; try state.save()
        let prior = try #require(state.previousDocuments().first)
        let external = Data("changed elsewhere".utf8); try external.write(to: url)
        #expect(throws: (any Error).self) { try state.recoverPreviousDocument(prior, title: "Recovered") }
        #expect(state.documents.count == 1 && state.documents[0].title == "Current")
        #expect(try Data(contentsOf: url) == external)
        let archives = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("personal-recovery"), includingPropertiesForKeys: nil)
        let archived = try JSONDecoder().decode(WorkspacePersonalSnapshot.self, from: Data(contentsOf: try #require(archives.first)))
        #expect(archived.documents == [prior])
    }
}
