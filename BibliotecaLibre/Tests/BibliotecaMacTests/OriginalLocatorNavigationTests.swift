import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LibronixCore
@testable import BibliotecaMac

@MainActor @Suite struct OriginalLocatorNavigationTests {
    @Test func originalLocatorUsesCheckedCCCTWidthsAndBothContextEndpoints() async throws {
        let fixture = try LinkedReaderFixture(); defer { fixture.remove() }
        let resource = fixture.resources[0], service = LegacyContentService()
        let context = ["start-article-length":"17","end-article-length":"17","start-hint":"%20%C2%B7%20John","start-hint-length":"3","end-hint":"John1","end-hint-length":"1"]
        let result = try await service.resolveArticleLocator(resource, originalResourceID: "LLS:1.0.3", position: "LLS-AOL:0.12.4", context: context)
        let content = try await service.read(resource.location, ordinal: result.location.sectionOrdinal)
        #expect(result.range == .init(location: 12, length: 4))
        #expect(result.sourceCharacterCount == 17 && content.plainText.utf16.count == 17)
        #expect((content.plainText as NSString).substring(with: result.range.nsRange) == "John")
        #expect(result.location.reference == "Jn 1:1")
        let staleCatalogIdentity = LibraryResource(location: resource.location, indexLocation: resource.indexLocation,
            title: resource.title, byteCount: resource.byteCount, format: resource.format,
            support: resource.support, provenance: resource.provenance, legacyIdentifier: fixture.resources[1].legacyIdentifier)
        await #expect(throws: LegacyLocatorError.self) { try await service.resolveArticleLocator(staleCatalogIdentity, originalResourceID: "LLS:1.0.4", position: "LLS-AOL:0.12.4") }
        await #expect(throws: LegacyLocatorError.self) { try await service.resolveArticleLocator(resource, originalResourceID: "LLS:1.0.4", position: "LLS-AOL:0.12.4") }
        var wrong = context; wrong["end-hint"] = "wrong"
        await #expect(throws: LegacyLocatorError.self) { try await service.resolveArticleLocator(resource, originalResourceID: "LLS:1.0.3", position: "LLS-AOL:0.12.4", context: wrong) }
    }
    @Test func invalidLabelsRangesAndChangedCharacterTablesCannotResolveAFalseDestination() async throws {
        let fixture = try LinkedReaderFixture(); defer { fixture.remove() }
        let resource = fixture.resources[0], service = LegacyContentService()
        for position in ["LLS-AOL:0<missing-label>.0.0","LLS-AOL:0.99.1","LLS-AOL:0.16.2","LLS-AOL:99.0.0"] {
            await #expect(throws: (any Error).self) { try await service.resolveArticleLocator(resource, originalResourceID: "LLS:1.0.3", position: position) }
        }
        let url = try #require(resource.indexLocation), metadata = try LegacyResourceReader.inspect(lsfURL: resource.location, lixURL: url)
        let block = try #require(metadata.lix?.blocks.first { $0.tag == "ccct" })
        var data = try Data(contentsOf: url); data[Int(block.offset)] += 1; try data.write(to: url)
        await #expect(throws: LegacyLocatorError.self) { try await service.resolveArticleLocator(resource, originalResourceID: "LLS:1.0.3", position: "LLS-AOL:0.12.4") }
    }
    @Test func importedSelectionNavigatesToItsSourceAndPersistsDerivedAnchorWithoutChangingOriginalFields() async throws {
        let fixture = try LinkedReaderFixture(); defer { fixture.remove() }
        let store = fixture.store(), model = LibraryModel(store: store)
        let source = Data("""
        <lbx-annotations name="Own imported notes"><annotation guid="own" resource-id="LLS:1.0.3" special="id=LLS:1.0.3|pos=LLS-AOL:0.12.4|start-article-length=17|end-article-length=17|start-hint=%20%C2%B7%20John|start-hint-length=3|end-hint=John1|end-hint-length=1"><title>Own original selection</title><content type="text/html"><![CDATA[<P>Own note body.</P>]]></content></annotation></lbx-annotations>
        """.utf8)
        let document = try StudyDocument.importingLegacyXML(source), note = try #require(document.notes.first)
        let id = try store.documents.insert(document)
        model.navigateNote(note, documentID: id)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (model.isResolvingOriginalDestination || model.reader.isLoading) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!model.isResolvingOriginalDestination && !model.reader.isLoading)
        #expect(model.destinationError == nil && model.reader.errorMessage == nil)
        #expect(model.reader.highlightRange == NSRange(location: 12, length: 4))
        #expect(model.reader.content?.plainText == "Edition A · John1")
        let resolved = try #require(store.documents.document(id)?.notes.first)
        #expect(resolved.anchor == note.anchor && resolved.sourceAttributes == note.sourceAttributes && resolved.sourceBody == note.sourceBody)
        #expect(resolved.resolvedAnchor?.selection == .init(location: 12, length: 4))
        #expect(model.readerAnnotations.count == 1)
        model.openAnnotation(try #require(model.readerAnnotations.first))
        #expect(model.section == .documents && model.selectedDocumentID == id && model.selectedNoteID == note.id)
        let reopened = StudyDocumentsStore(directory: fixture.root.appendingPathComponent("personal/Documents"))
        #expect(reopened.document(id)?.notes.first?.resolvedAnchor == resolved.resolvedAnchor)
    }
    @Test func annotationHighlightIsTemporaryAndCannotChangeCopiedBookFormattingOrCoordinates() throws {
        let text = "Own 🦉 selection", range = SearchTextRange(location: 7, length: 9)
        let annotation = ReaderAnnotation(documentID: UUID(), noteID: UUID(), title: "Own note", range: range)
        let hosting = NSHostingView(rootView: ReaderTextView(text: text, fontSize: 18, fontFamily: "serif", highlightRange: nil, annotations: [annotation]))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 320)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        func descendant(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.compactMap(descendant).first
        }
        let native = try #require(descendant(hosting)), storage = try #require(native.textStorage)
        #expect(native.string == text)
        #expect(storage.attribute(.backgroundColor, at: 7, effectiveRange: nil) == nil)
        #expect(native.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 7, effectiveRange: nil) != nil)
        #expect((native.string as NSString).substring(with: range.nsRange) == "selection")
        let clipboard = NSPasteboard.withUniqueName(); defer { clipboard.releaseGlobally() }
        native.setSelectedRange(range.nsRange); #expect(native.writeSelection(to: clipboard, types: native.writablePasteboardTypes))
        #expect(clipboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType")) == "selection")
    }
    @Test func originalFavoriteOpensItsCheckedPositionKeepsItsSourceAndCannotOverrideANewerDestination() async throws {
        let fixture = try LinkedReaderFixture(); defer { fixture.remove() }
        let store = fixture.store(), model = LibraryModel(store: store)
        let source = Data("""
        <favorites-collection><title>Favorites</title><favorite command="jump|pos=LLS-AOL:0.12.0|ref=bible.64.1.1|res=LLS:1.0.3"><title>Own original favorite</title></favorite></favorites-collection>
        """.utf8)
        let imported = try FavoritesDocument.importingLegacyXML(source), favorite = try #require(imported.items.first)
        store.personal.change { try $0.insert(favorite) }
        model.navigateFavorite(favorite)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (model.isResolvingOriginalDestination || model.reader.isLoading) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.reader.content?.plainText == "Edition A · John1")
        #expect(model.reader.highlightRange == NSRange(location: 12, length: 0))
        #expect(model.destinationError == nil && store.personal.favorites.items.first == favorite)
        var absent = favorite; absent.legacyCommand = "jump|pos=LLS-A:0|res=LLS:ABSENT"
        let before = model.reader.currentLocation
        model.navigateFavorite(absent)
        #expect(model.destinationError != nil && model.reader.currentLocation == before)
        model.navigateFavorite(favorite)
        let next = ReaderLocation(resourceID: fixture.resources[1].id, legacyIdentifier: fixture.resources[1].legacyIdentifier,
                                  format: .legacyLSF, sectionOrdinal: 1)
        model.navigate(next)
        let finalDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.reader.isLoading && ContinuousClock.now < finalDeadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!model.isResolvingOriginalDestination && model.reader.currentLocation?.resourceID == next.resourceID)
        #expect(model.reader.content?.plainText == "Edition B · John3" && store.personal.favorites.items.first == favorite)
    }
    @Test func readerLocatorAppliesRelativePositionsAndKeepsContentAfterAnInvalidRange() async throws {
        let fixture = try LinkedReaderFixture(); defer { fixture.remove() }
        let reader = ResourceReaderModel(); reader.open(fixture.resources[0], initialSection: 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reader.isLoading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        reader.locatorInput = "LLS-AOL:0.0.0::OLA:12.4.0"; reader.submitLocator()
        let secondDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reader.isLoading && ContinuousClock.now < secondDeadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(reader.highlightRange == NSRange(location: 12, length: 4))
        #expect(reader.currentLocation?.reference == "Jn 1:1" && reader.currentLocation?.characterOffset == 12)
        let previous = reader.currentLocation, history = reader.history
        reader.navigateToReference("LLS-AOL:0.999.1")
        let errorDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reader.isLoading && ContinuousClock.now < errorDeadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(reader.navigationMessage != nil && reader.currentLocation == previous && reader.history == history)
        #expect(reader.content?.plainText == "Edition A · John1" && reader.highlightRange == NSRange(location: 12, length: 4))
    }
}
