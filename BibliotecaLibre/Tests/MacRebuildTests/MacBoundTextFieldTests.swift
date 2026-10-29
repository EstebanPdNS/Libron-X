import AppKit
import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct MacBoundTextFieldTests {
    @Test func unfocusedAccessibilityWritesReachDistinctPersistedAnswers() throws {
        _ = NSApplication.shared
        let field = MacBoundTextField.Field()
        field.isEditable = true
        var expected = ""
        field.valueChanged = { expected = $0 }
        field.setAccessibilityValue("Primera respuesta")
        let first = StudyQuestion(prompt: "Primera pregunta", expectedAnswer: expected)
        field.setAccessibilityValue("Segunda respuesta")
        let second = StudyQuestion(prompt: "Segunda pregunta", expectedAnswer: expected)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("personal.json"), state = WorkspacePersonalState(url: path)
        try state.editStudyAssessments { $0.assessments.append(.init(title: "Owned", questions: [first, second])) }
        let reopened = WorkspacePersonalState(url: path)
        #expect(reopened.studyAssessments.assessments[0].questions.map(\.expectedAnswer) == ["Primera respuesta", "Segunda respuesta"])
        #expect(field.stringValue == "Segunda respuesta")
    }
    @Test func accessibilityBoundaryRejectsNontextAndDisabledChanges() {
        _ = NSApplication.shared
        let field = MacBoundTextField.Field()
        field.isEditable = true
        var value = "Original"
        field.stringValue = value; field.valueChanged = { value = $0 }
        field.setAccessibilityValue(42)
        #expect(field.stringValue == "Original" && value == "Original")
        field.isEnabled = false; field.setAccessibilityValue("Disabled edit")
        #expect(field.stringValue == "Original" && value == "Original")
    }
}
