import AppKit
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct ReaderInterlinearStateTests {
    private func resource() -> LibraryResource {
        .init(location: URL(fileURLWithPath: "/authored/interlinear.lbxlls"), title: "Authored interlinear", byteCount: 0,
              format: .libronixLLS, support: .metadataOnly, provenance: .fileName)
    }
    private func page() -> ReaderPage {
        ReaderPage(destination: .init(ordinal: 3), text: "cat", sectionCount: 6, interlinearLines: [
            .init(ordinal: 0, name: "surface", label: "Surface", visibleByDefault: true),
            .init(ordinal: 1, name: "lemma", label: "Lemma", visibleByDefault: true),
            .init(ordinal: 2, name: "transliteration", label: "Transliteration", visibleByDefault: false)])
    }
    @Test func lineChoicesFollowResourceDefaultsAndCannotHideEveryLine() {
        let reader = ReaderSession(resource: resource()); reader.page = page()
        #expect(reader.effectiveInterlinearLines == [0,1])
        reader.toggleInterlinearLine(2); reader.toggleInterlinearLine(1)
        #expect(reader.effectiveInterlinearLines == [0,2])
        reader.toggleInterlinearLine(0); reader.toggleInterlinearLine(2)
        #expect(reader.effectiveInterlinearLines == [2] && reader.page?.text == "cat")
        reader.visibleInterlinearLines = nil
        #expect(reader.effectiveInterlinearLines == [0,1])
    }
    @Test func selectedInterlinearWordsRebaseTheirDrawingRangeAndPartialSelectionsKeepOnlySelectedText() throws {
        let font = try #require(NSFont(name: "Times New Roman", size: 12))
        let rows = [NSAttributedString(string: "dog", attributes: [.font: font]), NSAttributedString(string: "κύων", attributes: [.font: font])]
        let unit = ReaderInterlinearGlyph(range: NSRange(location: 4, length: 3), rows: rows, rowHeights: [16,16], scale: 1)
        let source = NSMutableAttributedString(string: "cat dog!", attributes: [.font: font])
        source.addAttribute(.readerInterlinearUnit, value: unit, range: unit.sourceRange)
        let selected = ReaderOutputActions.selectedDocument(source, range: unit.sourceRange)
        let rebased = try #require(selected.attribute(.readerInterlinearUnit, at: 0, effectiveRange: nil) as? ReaderInterlinearGlyph)
        #expect(selected.string == "dog" && rebased.sourceRange == NSRange(location: 0, length: 3))
        #expect(rebased.rows.map(\.string) == ["dog","κύων"])
        let view = ReaderOutputActions.printView(selected, info: NSPrintInfo.shared)
        let layout = try #require(view.layoutManager), container = try #require(view.textContainer)
        let box = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        #expect(box.width >= unit.size.width - 1)
        let partial = ReaderOutputActions.selectedDocument(source, range: NSRange(location: 5, length: 1))
        #expect(partial.string == "o" && partial.attribute(.readerInterlinearUnit, at: 0, effectiveRange: nil) == nil)
        #expect(source.string == "cat dog!" && unit.sourceRange.location == 4)
    }

    @Test func duplicatedReadersAndWorkspaceFilesPreserveIndependentLineChoices() throws {
        let workspace = StudyWorkspace(), reader = workspace.open(resource(), startReading: false)
        reader.page = page(); reader.visibleInterlinearLines = [0,2]
        let duplicate = workspace.duplicate(reader)
        duplicate.toggleInterlinearLine(1)
        #expect(reader.effectiveInterlinearLines == [0,2] && duplicate.effectiveInterlinearLines == [0,1,2])
        let encoded = try JSONEncoder().encode(workspace.archive())
        let saved = try JSONDecoder().decode(WorkspaceArchive.self, from: encoded)
        try saved.validate()
        #expect(saved.panes.map(\.interlinearLines) == [[0,2],[0,1,2]])
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String:Any])
        var panes = try #require(object["panes"] as? [[String:Any]])
        for index in panes.indices { panes[index].removeValue(forKey: "interlinearLines") }
        object["panes"] = panes
        let legacy = try JSONDecoder().decode(WorkspaceArchive.self, from: JSONSerialization.data(withJSONObject: object))
        try legacy.validate()
        #expect(legacy.panes.allSatisfy { $0.interlinearLines == nil })
        var invalid = saved; invalid.panes[0].interlinearLines = [32]
        #expect(throws: PersonalStateError.self) { try invalid.validate() }
        invalid.panes[0].interlinearLines = []
        #expect(throws: PersonalStateError.self) { try invalid.validate() }
    }
}
