import Foundation
import AppKit
import LibronixCore
import Testing
@testable import MacRebuild

@Suite @MainActor struct BibleCopyStylePersistenceTests {
    @Test func customStylesPersistAndProtectConcurrentChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json")
        let first = WorkspacePersonalState(url: url), stale = WorkspacePersonalState(url: url)
        var style = BibleCopyOutputStyle(name: "Study")
        style.beforePassage.pattern = "^P (^a)^n"; style.beforeVerse.pattern = "^R "
        try first.editBibleCopyState { $0.customStyles.append(style); $0.selectedStyleID = style.id }
        let restored = WorkspacePersonalState(url: url)
        #expect(restored.bibleCopyState.customStyles == [style] && restored.bibleCopyState.selectedStyleID == style.id)
        #expect(throws: (any Error).self) { try stale.editBibleCopyState { $0.customStyles.append(style) } }
        var invalid = style; invalid.name = ""
        #expect(throws: (any Error).self) { try first.editBibleCopyState { $0.customStyles = [invalid] } }
        #expect(first.bibleCopyState.customStyles == [style])
        try first.editBibleCopyState { $0.customStyles.removeAll(); $0.selectedStyleID = BibleCopyOutputStyle.defaults[1].id }
        #expect(WorkspacePersonalState(url: url).bibleCopyState.customStyles.isEmpty)
    }
    @Test func futureSchemaCannotBeOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("bible-copy-styles.json"), bytes = Data(#"{"schemaVersion":99,"customStyles":[],"selectedStyleID":"00000000-0000-0000-0000-000000000002","passage":"John 1:1","keepOpen":false,"referenceLanguage":"english"}"#.utf8)
        try bytes.write(to: path)
        let state = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        #expect(state.bibleCopyLoadError != nil)
        #expect(throws: (any Error).self) { try state.editBibleCopyState { $0.customStyles.append(.init(name: "X")) } }
        #expect(try Data(contentsOf: path) == bytes)
    }
    @Test func applicationQuitCanBeBlockedForAnUnsavedTemplate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: state)
        workspace.copyStyleCloseGuard = { false }; #expect(!workspace.canQuitWithCopyStyleDraft())
        workspace.copyStyleCloseGuard = { true }; #expect(workspace.canQuitWithCopyStyleDraft())
        workspace.shutdown()
    }
    @Test func previewRetainsTextWithoutChangingClipboardSourceAttributes() {
        let original = NSMutableAttributedString(string: "Black and red")
        original.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: 6))
        original.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 10, length: 3))
        let preview = BibleCopyPreview.text(original)
        #expect(String(preview.characters) == original.string)
        let rendered = NSAttributedString(preview)
        #expect((rendered.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor) == .red)
        #expect((original.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .black)
        #expect((original.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor) == .red)
    }
}
