import AppKit
import Foundation
import Testing
import WebKit
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct ReaderPinnedNoteTests {
    @Test func clickedNoteSurvivesHoverDismissalFocusLossAndSourceControllerRelease() async throws {
        let resource = LibraryResource(location: URL(fileURLWithPath: "/authored/study.epub"), title: "Authored study Bible",
            byteCount: 0, format: .epub, support: .metadataOnly, provenance: .libronixMetadata)
        let link = LegacyInlineLink(range: .init(location: 0, length: 1), label: "1", sourceName: "explicit-comment-1", sectionOrdinal: 4)
        let initialCount = ReaderLinkPreviewController.pinnedPreviewCount
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = try #require(window.contentView)
        let article = NSView(frame: anchor.bounds); anchor.addSubview(article)
        window.orderFront(nil)
        defer { window.close() }
        var source: ReaderLinkPreviewController? = ReaderLinkPreviewController(loader: { _, destination in
            .init(destination: destination, text: "Authored persistent commentary", sectionCount: 5)
        })
        let note = try #require(source)
        note.resource = resource
        defer { note.close() }
        note.show(link, at: NSRect(x: 10, y: 10, width: 10, height: 10), in: article, hovering: false)
        for _ in 0..<100 where note.state.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(note.state.page?.text == "Authored persistent commentary")
        #expect(note.isPinned && note.popover.isShown && note.popover.behavior == .applicationDefined)
        note.cancelHover(); note.dismiss(); source = nil
        article.removeFromSuperview()
        window.makeKey()
        note.show(.init(range: .init(location: 0, length: 1), label: "2", sourceName: "other", sectionOrdinal: 3),
            at: .zero, in: anchor, hovering: true)
        #expect(note.state.link == link && note.popover.isShown)
        #expect(ReaderLinkPreviewController.pinnedPreviewCount == initialCount + 1)
        #expect(note.state.page != nil && note.state.error == nil)
        #expect(note.popover.contentSize.width == 400)
        note.close()
        #expect(!note.isPinned && !note.popover.isShown)
        #expect(ReaderLinkPreviewController.pinnedPreviewCount == initialCount)
    }
    @Test func onlyLinkedNumbersAndReferenceMarkersAreUnderlinedNeverVerseText() throws {
        let display = NSMutableAttributedString(string: "1 First verse. 2 Second verse. a Whole linked verse")
        var commentary = LegacyInlineLink(range: .init(location: 0, length: 1), label: "1", sourceName: "comment-1", sectionOrdinal: 4)
        commentary.role = .studyCommentary
        let ordinary = LegacyInlineLink(range: .init(location: 15, length: 1), label: "2", sourceName: "ordinary-2", sectionOrdinal: 5)
        let footnote = LegacyInlineLink(range: .init(location: 31, length: 2), label: "a ", sourceName: "note-a", sectionOrdinal: 6)
        let verse = LegacyInlineLink(range: .init(location: 33, length: 18), label: "Whole linked verse", sourceName: "verse", sectionOrdinal: 7)
        let anchor = LegacyReferenceAnchor(reference: "Ge 1:3", flags: 0, dataTypeCode: 0, characterOffset: 33, decodedOffset: 0)
        ReaderSourceLinkAttributes.install([commentary, ordinary, footnote, verse], in: display, verseAnchors: [anchor])
        #expect(display.string == "1 First verse. 2 Second verse. a Whole linked verse")
        #expect(display.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(display.attribute(.underlineStyle, at: 15, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(display.attribute(.underlineStyle, at: 31, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        for index in [2, 17, 32, 33, 48] { #expect(display.attribute(.underlineStyle, at: index, effectiveRange: nil) == nil) }
        #expect(display.attribute(.link, at: 0, effectiveRange: nil) != nil)
        let decoded = try JSONDecoder().decode(LegacyInlineLink.self, from: JSONEncoder().encode(commentary))
        #expect(decoded.role == .studyCommentary && decoded.range == commentary.range && decoded.target == commentary.target)
        let old = Data(#"{"range":[0,1],"label":"1","sourceName":"legacy","target":{"article":{"_0":4}}}"#.utf8)
        #expect(try JSONDecoder().decode(LegacyInlineLink.self, from: old).role == nil)
    }
    @Test func referencesAndTextLinksShareTheMarkerStyleAcrossResourceFormats() {
        let display = NSMutableAttributedString(string: "1:9 See the map. 2 Full verse text.")
        let reference = LegacyInlineLink(range: .init(location: 0, length: 3), label: "1:9", sourceName: "reference", sectionOrdinal: 1)
        let title = LegacyInlineLink(range: .init(location: 4, length: 12), label: "See the map.", sourceName: "map", sectionOrdinal: 2)
        let verse = LegacyInlineLink(range: .init(location: 17, length: 18), label: "2 Full verse text.", sourceName: "verse", sectionOrdinal: 3)
        let anchor = LegacyReferenceAnchor(reference: "Ge 1:2", flags: 0, dataTypeCode: 0, characterOffset: 17, decodedOffset: 0)
        ReaderSourceLinkAttributes.install([reference, title, verse], in: display, verseAnchors: [anchor])
        for index in [0, 2, 4, 15, 17] {
            #expect(display.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
            #expect(display.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor == NSColor.linkColor)
        }
        for index in [3, 16, 18, 25, 34] { #expect(display.attribute(.underlineStyle, at: index, effectiveRange: nil) == nil) }
        #expect(display.string == "1:9 See the map. 2 Full verse text.")
    }
    @Test func htmlReadersUseTheSameBlueUnderlineWithoutRestylingTheVerseBody() async throws {
        let fixture = try AuthoredOEBFixture(chapterBody: ##"<span id="a1"></span><p>1 <a href="#a2" style="color:red;text-decoration:none"><span style="color:green">a</span></a> Authored verse body. <a href="#a2">Ge 1:1</a></p><span id="a2"></span><p>Authored note.</p>"##)
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.resource.location)
        let reader = ReaderSession(resource: fixture.resource)
        reader.page = try await ReaderSession.read(fixture.resource, .init(ordinal: 1))
        let coordinator = ReaderOEBView.Coordinator(reader: reader, activate: {})
        let view = ReaderOEBView.makeWebView(reader: reader, coordinator: coordinator)
        defer { ReaderOEBView.dismantleNSView(view, coordinator: coordinator); reader.cancel() }
        coordinator.begin(try #require(reader.page?.oeb), in: view)
        let deadline = Date().addingTimeInterval(10)
        while !coordinator.ready && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(coordinator.ready)
        let result = try await view.callAsyncJavaScript("return {links:Array.from(document.querySelectorAll('a[href],a[href] span')).map(e=>({color:getComputedStyle(e).color,underline:getComputedStyle(e).textDecorationLine})),body:getComputedStyle(document.querySelector('p')).textDecorationLine,text:document.body.innerText};", in: nil, contentWorld: .defaultClient)
        let styles = try #require(result as? [String: Any])
        let links = try #require(styles["links"] as? [[String: String]])
        #expect(links.count == 3 && links.allSatisfy { $0["color"] == "rgb(0, 104, 218)" && $0["underline"] == "underline" })
        #expect(styles["body"] as? String == "none")
        #expect((styles["text"] as? String)?.contains("Authored verse body.") == true)
        #expect(try Data(contentsOf: fixture.resource.location) == original)
    }
}
