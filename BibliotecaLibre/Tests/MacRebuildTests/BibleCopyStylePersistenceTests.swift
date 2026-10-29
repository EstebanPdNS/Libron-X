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
        style.greek = .transliterated; style.hebrew = .transliterated; style.hebrewLetters = .consonantsOnly
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
    @Test func nativePreviewRetainsRichTextWithoutChangingSourceAttributes() {
        let source = NSMutableAttributedString(string: "Black and red")
        source.addAttribute(.foregroundColor, value: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), range: NSRange(location: 0, length: 6))
        source.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 10, length: 3))
        let paragraph = NSMutableParagraphStyle(); paragraph.baseWritingDirection = .rightToLeft; paragraph.alignment = .right
        source.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: source.length))
        let view = MacAttributedPreview.Coordinator(); view.update(source)
        #expect(view.textView.string == source.string)
        #expect(view.textView.attributedString().isEqual(to: source))
        #expect(view.textView.usesAdaptiveColorMappingForDarkAppearance)
        #expect(!view.textView.isEditable && view.textView.isSelectable)
        #expect((view.textView.attributedString().attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.baseWritingDirection == .rightToLeft)
        #expect((source.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor) == .red)
    }
    @Test func includedTemplateNamesArePresentInEveryInterfaceLanguage() throws {
        for style in BibleCopyOutputStyle.defaults {
            let translations = try #require(AppStrings.catalog[style.name])
            for language in AppLanguage.allCases {
                #expect(translations[language.rawValue]?.isEmpty == false)
            }
        }
    }

    @Test func nativePreviewPreservesSelectionAcrossUnchangedUpdatesAndKeepsColorsForOutput() {
        let view = MacAttributedPreview.Coordinator()
        for color in [NSColor.black, NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), NSColor(calibratedWhite: 0, alpha: 1)] {
            let source = NSAttributedString(string: "😀 Native preview", attributes: [.foregroundColor: color])
            view.update(source); view.textView.setSelectedRange(NSRange(location: 3, length: 6)); view.update(source)
            #expect(view.textView.selectedRange() == NSRange(location: 3, length: 6))
            #expect(view.textView.attributedString().isEqual(to: source))
            #expect(view.textView.usesAdaptiveColorMappingForDarkAppearance)
        }
        view.update(NSAttributedString(string: "New"))
        #expect(view.textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func historySnippetsAdaptOpaqueRGBBlackWithoutRecoloringSourceOrColoredText() throws {
        let appearance = try #require(NSAppearance(named: .darkAqua))
        appearance.performAsCurrentDrawingAppearance {
            let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            let source = NSMutableAttributedString(string: "Black red", attributes: [.foregroundColor: black])
            source.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 6, length: 3))
            let rendered = NSAttributedString(MacAttributedPreview.inlineText(source))
            let foreground = (rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
            #expect((foreground?.redComponent ?? 0) > 0.5)
            #expect((rendered.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor) == .red)
            #expect((source.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == black)
        }
    }

}
