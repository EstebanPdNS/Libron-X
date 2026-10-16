import AppKit
import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct BibleSwitchTests {
    private func page(_ fixture: AuthoredReaderFixture, reference: String = "Ge 3:5") throws -> ReaderPage {
        let base = try LegacyContentReader.readSection(lsfURL: fixture.resources[0].location, ordinal: 0)
        let anchor = LegacyReferenceAnchor(reference: "bible.1.3.5", flags: 0, dataTypeCode: 16,
            characterOffset: 7, decodedOffset: 7, referenceFormatFlags: 0)
        let content = LegacySectionContent(descriptor: base.descriptor, plainText: base.plainText, runs: base.runs,
            expectedCharacterCount: base.expectedCharacterCount, recognizedFormat: base.recognizedFormat,
            paragraphs: base.paragraphs, anchors: [anchor], markers: [], graphics: [], warnings: [], paragraphDocuments: nil)
        return .init(destination: .init(ordinal: 0, reference: reference), text: base.plainText, sectionCount: 1,
                     selection: .init(location: 7, length: 0), content: content)
    }
    private func settle(_ reader: ReaderSession) async throws {
        for _ in 0..<2000 {
            if !reader.isLoading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Version switch did not settle")
    }
    @Test func replacementRetainsWindowVerseAndLinkIdentityWithoutNavigatingPeers() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["First. Verse five."], ["Other. Verse five."]]); defer { fixture.remove() }
        let replacementPage = try page(fixture)
        let reader = ReaderSession(resource: fixture.resources[0], loader: { _, requested in
            #expect(requested.ordinal == 0 && requested.reference == "Ge 3:5")
            return replacementPage
        })
        reader.page = replacementPage; reader.visibleBibleReference = "Ge 3:5"
        reader.frame = .init(x: 0.2, y: 0.1, width: 0.5, height: 0.8)
        reader.linkGroup = .b; reader.textScale = 1.25; reader.showsContents = true
        reader.history = [.init(ordinal: 999, reference: "Ge 1:1")]; reader.historyIndex = 0
        let id = reader.id, frame = reader.frame
        var broadcasts = 0, commits = 0
        reader.onReferenceNavigation = { _ in broadcasts += 1 }
        reader.changeBibleVersion(to: fixture.resources[1], reference: "Ge 3:5") { commits += 1 }
        try await settle(reader)
        #expect(reader.resource.id == fixture.resources[1].id && reader.id == id)
        #expect(reader.frame == frame && reader.linkGroup == .b && reader.textScale == 1.25 && reader.showsContents)
        #expect(reader.currentReference == "Ge 3:5" && reader.viewportCharacterOffset == 7)
        #expect(reader.history == [replacementPage.destination] && reader.historyIndex == 0)
        #expect(broadcasts == 0 && commits == 1 && reader.error == nil)
    }
    @Test func failedVersionLeavesCommittedBookAndSelectionIntact() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["First. Verse five."], ["Other."]]); defer { fixture.remove() }
        let previous = try page(fixture)
        let reader = ReaderSession(resource: fixture.resources[0], loader: { _, _ in throw RebuildError.referenceNotFound })
        reader.page = previous; reader.history = [previous.destination]; reader.historyIndex = 0
        reader.selectedRange = .init(location: 7, length: 5); reader.visibleBibleReference = "Ge 3:5"
        reader.changeBibleVersion(to: fixture.resources[1], reference: "Ge 3:5")
        try await settle(reader)
        #expect(reader.resource == fixture.resources[0] && reader.page?.text == previous.text)
        #expect(reader.selectedRange == NSRange(location: 7, length: 5) && reader.currentReference == "Ge 3:5")
        #expect(reader.history == [previous.destination] && reader.error != nil)
    }
    @Test func skipsUnavailablePassageAndRejectsWrongVerse() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["First. Verse five."], ["Missing"], ["Wrong verse"], ["Correct"]]); defer { fixture.remove() }
        let result = try page(fixture)
        let reader = ReaderSession(resource: fixture.resources[0], loader: { resource, _ in
            if resource.id == fixture.resources[1].id { throw RebuildError.referenceNotFound }
            if resource.id == fixture.resources[2].id { return .init(destination: .init(ordinal: 0), text: "Wrong", sectionCount: 1) }
            return result
        })
        reader.page = result
        reader.changeBibleVersion(candidates: Array(fixture.resources.dropFirst()), reference: "Ge 3:5")
        try await settle(reader)
        #expect(reader.resource.id == fixture.resources[3].id && reader.currentReference == "Ge 3:5")
    }
    @Test func cancellationCannotReplaceANewerNavigation() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["First. Verse five."], ["Other."]]); defer { fixture.remove() }
        let result = try page(fixture)
        let reader = ReaderSession(resource: fixture.resources[0], loader: { _, _ in
            try? await Task.sleep(for: .milliseconds(40)); return result
        })
        reader.page = result
        reader.changeBibleVersion(to: fixture.resources[1], reference: "Ge 3:5")
        reader.cancel()
        try await Task.sleep(for: .milliseconds(60))
        #expect(reader.resource.id == fixture.resources[0].id && !reader.isLoading)
    }
    @Test func arrowRoutingPreservesTextEditingAndModifiedShortcuts() throws {
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        let reading = NSTextView(); reading.isEditable = false
        #expect(BibleVersionKeyboardRouting.KeyView.accepts(try key(124), responder: reading))
        #expect(BibleVersionKeyboardRouting.KeyView.accepts(try key(123, [.numericPad, .function]), responder: reading))
        for flags: NSEvent.ModifierFlags in [.command, .shift, .option, .control] {
            #expect(!BibleVersionKeyboardRouting.KeyView.accepts(try key(124, flags), responder: reading))
        }
        let editing = NSTextView(); editing.isEditable = true
        for responder: NSResponder in [editing, NSTextField(), NSSearchField(), NSComboBox()] {
            #expect(!BibleVersionKeyboardRouting.KeyView.accepts(try key(124), responder: responder))
        }
        #expect(!BibleVersionKeyboardRouting.KeyView.accepts(try key(125), responder: reading))
    }
    @Test func sourceDeclarationsExcludeCommentariesAndIncludeObservedLegacyBibles() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_BIBLE_VERSION_CORPUS"] else { return }
        let root = URL(fileURLWithPath: path)
        let imported = try await LibraryImporter().importDirectory(at: root) { _ in }
        let legacy = Set(imported.resources.filter { ["RVR60.LSF", "RVR95.LSF"].contains($0.fileName) }.map(\.id))
        let catalog = BibleVersionCatalog()
        let versions = try await catalog.versions(in: imported.resources, observed: legacy)
        let nextPass = try await catalog.versions(in: imported.resources, observed: [])
        #expect(nextPass.map(\.id) == versions.map(\.id))
        #expect(versions.contains { $0.fileName == "RVR60.LSF" })
        #expect(versions.contains { $0.fileName == "RVR95BTO.lbxlls" })
        #expect(!versions.contains { $0.fileName == "JFBCOMM.lbxlls" || $0.fileName == "STRCONCES.lbxlls" })
        #expect(Set(versions.map(\.id)).count == versions.count)
        print("Bible version catalog: \(versions.count) declared/observed Bibles; commentaries excluded")
    }
    @Test func realLSFAndLLSEditionsRetainExactVerse() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_BIBLE_VERSION_CORPUS"] else { return }
        let imported = try await LibraryImporter().importDirectory(at: URL(fileURLWithPath: path)) { _ in }
        let names = ["RVR60.LSF", "RVR95.LSF", "RVR95BTO.lbxlls", "LBLA95.lbxlls", "NVI.lbxlls"]
        let resources = try names.map { name in try #require(imported.resources.first { $0.fileName == name }) }
        let reader = ReaderSession(resource: resources[0]); defer { reader.cancel() }
        reader.load(.init(ordinal: 0, reference: "Ge 3:5"), propagateReference: false)
        try await settle(reader)
        #expect(reader.currentReference == "Ge 3:5")
        for resource in resources.dropFirst() + [resources[0]] {
            reader.changeBibleVersion(to: resource, reference: "Ge 3:5")
            try await settle(reader)
            #expect(reader.resource.id == resource.id && reader.currentReference == "Ge 3:5" && reader.error == nil)
            #expect(reader.viewportCharacterOffset == reader.page?.selection?.location)
        }
        print("Bible replacement: 5 source editions, LSF and LLS, exact Ge 3:5 and reverse format transition")
    }
}
