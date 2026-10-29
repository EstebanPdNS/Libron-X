import Foundation
import Testing
@testable import MacRebuild

@Suite(.serialized) @MainActor struct MarkPaletteTests {
    @Test func selectedPalettePersistsAndLegacyColorsRemainDefault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("personal.json"), state = WorkspacePersonalState(url: url)
        #expect(state.markPalettes.selectedColors == MarkColor.allCases)
        let palette = MarkPalette(name: "Study", colors: [.blue, .pink])
        try state.editMarkPalettes { $0.palettes.append(palette); $0.selectedID = palette.id }
        let reopened = WorkspacePersonalState(url: url)
        #expect(reopened.markPalettes.selectedColors == [.blue, .pink])
        try reopened.editMarkPalettes { $0.palettes.removeAll(); $0.selectedID = nil }
        #expect(reopened.markPalettes.selectedColors == MarkColor.allCases)
    }
    @Test func invalidPaletteCannotBeSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = WorkspacePersonalState(url: directory.appendingPathComponent("personal.json"))
        #expect(throws: (any Error).self) { try state.editMarkPalettes { $0.palettes.append(.init(name: "", colors: [.blue])) } }
        #expect(throws: (any Error).self) { try state.editMarkPalettes { $0.palettes.append(.init(name: "Bad", colors: [])) } }
        #expect(state.markPalettes.palettes.isEmpty)
    }
}
