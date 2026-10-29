import AppKit
import Foundation
import Testing
@testable import MacRebuild

@Suite(.serialized) @MainActor struct ReaderMarkStyleTests {
    private func mark(style: ReaderMarkStyle? = nil) -> ReaderHighlight {
        ReaderHighlight(resourceID: "resource", ordinal: 0, fingerprint: "hash", range: NSRange(location: 0, length: 3), color: "blue", style: style)
    }
    @Test func legacyAndNewStylesUseSafeSchemaVersions() throws {
        let old = WorkspacePersonalSnapshot(highlights: [mark()])
        try old.validate()
        let decoded = try JSONDecoder().decode(WorkspacePersonalSnapshot.self, from: JSONEncoder().encode(old))
        #expect(decoded.highlights.first?.style == nil)
        var modern = WorkspacePersonalSnapshot(highlights: [mark(style: .underline)])
        #expect(throws: (any Error).self) { try modern.validate() }
        modern.schemaVersion = 2; try modern.validate()
        let encoded = String(decoding: try JSONEncoder().encode(modern), as: UTF8.self).replacingOccurrences(of: "underline", with: "unknown")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WorkspacePersonalSnapshot.self, from: Data(encoded.utf8)) }
    }
    @Test func renderingKeepsTheSelectedStyleAndBounds() {
        let background = NSMutableAttributedString(string: "Example")
        ReaderMarkPresentation.apply(mark(), to: background)
        #expect(background.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        let underline = NSMutableAttributedString(string: "Example")
        ReaderMarkPresentation.apply(mark(style: .underline), to: underline)
        #expect(underline.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
        #expect(underline.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        let strike = NSMutableAttributedString(string: "Example")
        ReaderMarkPresentation.apply(mark(style: .strike), to: strike)
        #expect(strike.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil)
        let outline = NSMutableAttributedString(string: "Example")
        ReaderMarkPresentation.apply(mark(style: .outline), to: outline)
        #expect(outline.attribute(.readerMarkOutline, at: 0, effectiveRange: nil) != nil)
        var invalid = mark(style: .underline); invalid.range = NSRange(location: 5, length: 20)
        ReaderMarkPresentation.apply(invalid, to: strike)
        #expect(strike.attribute(.underlineStyle, at: 5, effectiveRange: nil) == nil)
    }
    @Test func stylesSurviveSavingAndReloading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("personal.json"), state = WorkspacePersonalState(url: url)
        state.highlights = [mark(), mark(style: .underline), mark(style: .strike), mark(style: .outline)]
        try state.save()
        let stored = try JSONDecoder().decode(WorkspacePersonalSnapshot.self, from: Data(contentsOf: url))
        #expect(stored.schemaVersion == 2)
        #expect(WorkspacePersonalState(url: url).highlights == state.highlights)
    }
}
