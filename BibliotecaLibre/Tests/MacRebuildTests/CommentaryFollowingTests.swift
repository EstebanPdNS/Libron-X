import AppKit
import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct CommentaryFollowingTests {
    private func bible(_ fixture: AuthoredReaderFixture) throws -> ReaderPage {
        let base = try LegacyContentReader.readSection(lsfURL: fixture.resources[0].location, ordinal: 0)
        let anchors = [0, 7, 15].enumerated().map { index, offset in
            LegacyReferenceAnchor(reference: "Ge 1:\(index + 1)", flags: 0, dataTypeCode: 16,
                characterOffset: offset, decodedOffset: UInt64(offset), referenceFormatFlags: 0)
        }
        let content = LegacySectionContent(descriptor: base.descriptor, plainText: base.plainText, runs: base.runs,
            expectedCharacterCount: base.expectedCharacterCount, recognizedFormat: base.recognizedFormat,
            paragraphs: base.paragraphs, anchors: anchors, markers: [], graphics: [], warnings: [], paragraphDocuments: nil)
        let links = [0, 7].enumerated().map { index, offset in
            var link = LegacyInlineLink(range: .init(location: offset, length: 1), label: "\(index + 1)",
                sourceName: "explicit-commentary", sectionOrdinal: index + 1)
            link.role = .studyCommentary
            return link
        }
        return .init(destination: .init(ordinal: 0), text: base.plainText, sectionCount: 3, content: content, inlineLinks: links)
    }
    private func settle(_ reader: ReaderSession) async throws {
        for _ in 0..<1000 {
            if !reader.isLoading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Commentary did not settle")
    }
    @Test func openingCommentaryFollowsOwnedVerseLinksWithoutStealingFocusOrAddingHistory() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["First. Second. Third.", "First commentary", "Second commentary"]])
        defer { fixture.remove() }
        let workspace = StudyWorkspace()
        let source = workspace.open(fixture.resources[0], startReading: false)
        source.page = try bible(fixture); source.visibleBibleReference = "Ge 1:1"
        workspace.openInlineLink(source.resource, destination: .init(ordinal: 1), from: source, newReader: true)
        let target = try #require(workspace.activeReader)
        #expect(target.commentarySourceID == source.id)
        try await settle(target)
        let history = target.history
        workspace.activate(source)
        source.observeBiblePosition(7, fromViewport: true)
        try await settle(target)
        #expect(target.page?.text.contains("Second commentary") == true)
        #expect(target.history == history && source.history.isEmpty && workspace.activeID == source.id)
        source.observeBiblePosition(15, fromViewport: true)
        #expect(target.page == nil && target.commentaryReference == "Ge 1:3" && target.error == nil)
        source.observeBiblePosition(0, fromViewport: true)
        try await settle(target)
        #expect(target.page?.text.contains("First commentary") == true && target.error == nil)
    }
    @Test func articleHistoryReturnsToTheCurrentFollowedNoteAndForwardAgain() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["First. Second. Third.", "First commentary", "Second commentary", "Study article"]])
        defer { fixture.remove() }
        let workspace = StudyWorkspace()
        let source = workspace.open(fixture.resources[0], startReading: false)
        source.page = try bible(fixture); source.visibleBibleReference = "Ge 1:1"
        workspace.openInlineLink(source.resource, destination: .init(ordinal: 1), from: source, newReader: true)
        let target = try #require(workspace.activeReader)
        try await settle(target)
        source.observeBiblePosition(7, fromViewport: true)
        try await settle(target)
        #expect(target.canGoBack)
        target.goBack(); try await settle(target)
        #expect(target.page?.destination.ordinal == 1 && target.canGoForward)
        target.goForward(); try await settle(target)
        #expect(target.page?.destination.ordinal == 2)
        workspace.openInlineLink(source.resource, destination: .init(ordinal: 3), from: source, newReader: true)
        try await settle(target)
        #expect(target.history.map(\.ordinal) == [1, 2, 3] && target.canGoBack && !target.canGoForward)
        target.goBack(); try await settle(target)
        #expect(target.page?.text.contains("Second commentary") == true && target.canGoForward)
        target.goForward(); try await settle(target)
        #expect(target.page?.text.contains("Study article") == true && !target.canGoForward)
        workspace.closeAll()
    }

    @Test func BibleReferenceReadingsStaySeparateAndPausedCommentariesStayIndependent() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["First. Second. Third.", "First commentary", "Second commentary"]])
        defer { fixture.remove() }
        let workspace = StudyWorkspace()
        let source = workspace.open(fixture.resources[0], startReading: false)
        source.page = try bible(fixture); source.visibleBibleReference = "Ge 1:1"
        workspace.openInlineLink(source.resource, destination: .init(ordinal: 0, reference: "Ge 1:1"), from: source, newReader: true)
        let ordinary = try #require(workspace.activeReader)
        #expect(ordinary.commentarySourceID == nil)
        workspace.openInlineLink(source.resource, destination: .init(ordinal: 1), from: source, newReader: true)
        let target = try #require(workspace.activeReader)
        try await settle(target)
        target.followsCommentary = false
        source.observeBiblePosition(7, fromViewport: true)
        #expect(target.page?.destination.ordinal == 1)
        target.followsCommentary = true
        workspace.updateCommentaryFollowers(from: source, reference: "Ge 1:2")
        try await settle(target)
        #expect(target.page?.destination.ordinal == 2)
        workspace.close(source)
        #expect(target.commentarySourceID == nil)
        ordinary.cancel()
    }
    @Test func rapidScrollingDiscardsOldUncooperativeReadsAndWorkspaceLinksRoundTrip() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["First. Second. Third.", "First commentary", "Second commentary"]])
        defer { fixture.remove() }
        let workspace = StudyWorkspace()
        workspace.resources = fixture.resources
        let source = workspace.open(fixture.resources[0], startReading: false)
        let base = try bible(fixture)
        source.page = base; source.visibleBibleReference = "Ge 1:1"
        let target = workspace.open(source.resource, startReading: false, loader: { _, destination in
            try? await Task.sleep(for: .milliseconds(destination.ordinal == 1 ? 80 : 5))
            var result = base; result.destination = destination
            return result
        })
        target.commentarySourceID = source.id; target.commentaryResourceID = source.resource.id
        workspace.updateCommentaryFollowers(from: source, reference: "Ge 1:1")
        source.observeBiblePosition(7, fromViewport: true)
        try await settle(target)
        try await Task.sleep(for: .milliseconds(100))
        #expect(target.page?.destination.ordinal == 2 && target.history.isEmpty)
        let saved = workspace.archive()
        try saved.validate()
        let restored = StudyWorkspace()
        try restored.restore(JSONDecoder().decode(WorkspaceArchive.self, from: JSONEncoder().encode(saved)))
        #expect(restored.readers[1].commentarySourceID == restored.readers[0].id)
        #expect(restored.readers[1].commentaryResourceID == restored.readers[0].resource.id)
        var invalid = saved; invalid.panes[1].commentarySourceIndex = 1
        #expect(throws: (any Error).self) { try invalid.validate() }
        restored.closeAll()
    }
    @Test func linksInBufferedChaptersKeepTheirOwnReferenceContext() throws {
        let fixture = try AuthoredReaderFixture(documents: [["First. Second. Third.", "First commentary", "Second commentary"]])
        defer { fixture.remove() }
        let workspace = StudyWorkspace()
        let source = workspace.open(fixture.resources[0], startReading: false)
        let previous = try bible(fixture)
        var current = previous; current.destination.ordinal = 2; current.inlineLinks = []
        source.page = current; source.flowPages = [previous, current]; source.visibleBibleReference = "Ge 1:3"
        workspace.openInlineLink(source.resource, destination: .init(ordinal: 1), from: source, newReader: true)
        let companion = try #require(workspace.activeReader)
        #expect(companion.commentaryReference == "Ge 1:1" && source.currentReference == "Ge 1:3")
        workspace.closeAll()
    }

    @Test func chapterFindAndExportUseTheVisibleChapterAndKeepTheBibleIndependent() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored"]]); defer { fixture.remove() }
        let reader = ReaderSession(resource: fixture.resources[0])
        reader.page = .init(destination: .init(ordinal: 10, commentaryChapter: "ge 1:1"),
            text: "First note. Second note. Last note.", sectionCount: 30)
        reader.commentaryResourceID = reader.resource.id; reader.commentaryReference = "Ge 1:2"
        reader.findQuery = "note"
        reader.find(.forward)
        #expect(reader.selectedText == "note" && reader.selectedRange.location == 6)
        reader.find(.forward)
        #expect(reader.selectedRange.location == 19 && reader.commentaryReference == "Ge 1:2")
        #expect(try ReaderOutputActions.document(reader).string == reader.page?.text)
        #expect(try ReaderOutputActions.document(reader, selectionOnly: true).string == "note")
        reader.findQuery = "missing"
        reader.find(.forward)
        #expect(reader.findStatus == .notFound && reader.selectedRange.location == 19)
    }

    @Test func openingAnArticleRemembersTheLatestVerseWithinACommentaryChapter() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored"]]); defer { fixture.remove() }
        let reader = ReaderSession(resource: fixture.resources[0], loader: { _, destination in
            .init(destination: destination, text: "Authored notes.", sectionCount: 10)
        })
        reader.commentaryResourceID = reader.resource.id
        let initial = ReaderDestination(ordinal: 0, reference: "Ge 1:1", commentaryChapter: "ge 1:1")
        reader.page = .init(destination: initial, text: "Authored notes.", sectionCount: 10)
        reader.history = [initial]; reader.historyIndex = 0; reader.commentaryReference = "Ge 1:26"
        reader.rememberCommentaryLocation()
        #expect(reader.history.last?.reference == "Ge 1:26" && reader.history.last?.commentaryChapter == "ge 1:1")
        reader.commentaryReference = "Ge 1:1"
        reader.load(.init(ordinal: 0, reference: "Ge 1:26", commentaryChapter: "ge 1:1"))
        try await settle(reader)
        #expect(reader.commentaryReference == "Ge 1:26")
    }

    @Test func inspectedStudyBibleCommentariesFollowAndTheophaniesReusesTheCompanionPane() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_VERIFY_NKJV_NATIVE"] else { return }
        let catalog = try LibronCatalog.load(from: URL(fileURLWithPath: path))
        for title in ["The NKJV Study Bible: Second Edition", "NKJV Study Bible, Full-Color"] {
            let resource = try #require(catalog.resources.first { $0.title == title })
            let workspace = StudyWorkspace()
            workspace.resources = [resource]
            let source = workspace.open(resource, startReading: false)
            source.page = try await LibronNativeReader.shared.read(resource, .init(ordinal: 0, reference: "Ru 3:1"))
            source.visibleBibleReference = "Ru 3:1"
            let link = try #require(source.page?.inlineLinks.first { $0.role == .studyCommentary })
            workspace.openInlineLink(resource, destination: .init(ordinal: try #require(link.sectionOrdinal)), from: source, newReader: true)
            let target = try #require(workspace.activeReader)
            try await settle(target)
            #expect(target.isCommentary && !target.canSynchronizeBible && target.displayTitle != resource.title)
            let second = try #require(source.page?.content?.anchors.first {
                $0.reference.flatMap(LegacyPassageQuery.sourceReference)?.normalizedKey == "ru 3:2"
            })
            workspace.activate(source)
            source.observeBiblePosition(second.characterOffset, fromViewport: true)
            try await settle(target)
            #expect(target.commentaryReference == "Ru 3:2" && target.page != nil && workspace.activeID == source.id)
            source.page = try await LibronNativeReader.shared.read(resource, .init(ordinal: 0, reference: "Da 4:1"))
            source.visibleBibleReference = "Da 4:1"
            try await settle(target)
            let firstNote = try #require(target.page?.destination.ordinal)
            for verse in [2, 3, 1, 3, 2] {
                let anchor = try #require(source.page?.content?.anchors.first {
                    $0.reference.flatMap(LegacyPassageQuery.sourceReference)?.normalizedKey == "da 4:\(verse)"
                })
                source.observeBiblePosition(anchor.characterOffset, fromViewport: true)
                try await settle(target)
                #expect(target.page?.destination.ordinal == firstNote && target.page.map { ($0.text as NSString).substring(from: target.viewportCharacterOffset ?? 0).hasPrefix("4:1–3") } == true)
                #expect(target.commentaryReference == "Da 4:\(verse)")
            }
            for verse in [10, 11, 14, 15, 16, 17, 18, 6] {
                let anchor = try #require(source.page?.content?.anchors.first {
                    $0.reference.flatMap(LegacyPassageQuery.sourceReference)?.normalizedKey == "da 4:\(verse)"
                })
                source.observeBiblePosition(anchor.characterOffset, fromViewport: true)
                try await settle(target)
                let page = try #require(target.page)
                let visible = (page.text as NSString).substring(from: target.viewportCharacterOffset ?? 0)
                if verse == 6 { #expect(visible.hasPrefix("4:5 ")) }
                else if verse >= 15 { #expect(visible.hasPrefix("4:\(verse) ")) }
                else { #expect(visible.hasPrefix("4:10–17")) }
                #expect(page.text.contains("4:34 ") && page.destination.commentaryChapter == "da 4:1")
            }
            for reference in ["Da 6:13", "Ge 1:3", "Jn 3:16", "Re 22:21"] {
                source.page = try await LibronNativeReader.shared.read(resource, .init(ordinal: 0, reference: reference))
                source.visibleBibleReference = reference
                try await settle(target)
                let key = try #require(LegacyPassageQuery.sourceReference(reference))
                #expect(target.commentaryReference == reference)
                #expect(target.page?.destination.commentaryChapter == "\(key.sourceBookKey) \(key.chapter):1")
                #expect(target.viewportCharacterOffset == target.page?.commentaryLocations[key.normalizedKey])
                if reference == "Da 6:13" {
                    #expect(target.page.map { ($0.text as NSString).substring(from: target.viewportCharacterOffset ?? 0).hasPrefix("6:13") } == true)
                }
            }
            if title == "NKJV Study Bible, Full-Color" {
                source.page = try await LibronNativeReader.shared.read(resource, .init(ordinal: 0, reference: "Da 3:25"))
                source.visibleBibleReference = "Da 3:25"
                let article = try #require(source.page?.inlineLinks.first { $0.label.contains("Theophanies") })
                workspace.openInlineLink(resource, destination: .init(ordinal: try #require(article.sectionOrdinal)), from: source, newReader: true)
                #expect(workspace.readers.count == 2 && workspace.activeID == target.id)
                try await settle(target)
                let page = try #require(target.page)
                #expect(page.text.contains("Theophanies") && page.graphics.count == 4)
                let illustrations = page.graphics.filter { !ReaderImageRenderer.isDecoration($0) }
                let illustration = try #require(illustrations.first)
                #expect(illustrations.count == 1 && ReaderImageRenderer.decode(illustration.data) != nil)
                let rendered = ReaderTypography.render(text: page.text, content: page.content, typography: page.typography, scale: 1)
                let display = NSMutableAttributedString(attributedString: rendered.text)
                let result = ReaderImageRenderer.install(page.graphics, in: display, detached: true)
                #expect(result.images.isEmpty && result.warnings.isEmpty && display.length == page.text.utf16.count)
                for asset in page.graphics {
                    #expect(display.attribute(.attachment, at: asset.graphic.objectCharacterOffset, effectiveRange: nil) == nil)
                }
                let inline = NSMutableAttributedString(attributedString: rendered.text)
                #expect(ReaderImageRenderer.install(page.graphics, in: inline).images.count == 1)
                source.selectedRange = try #require(source.page?.selection)
                source.viewportCharacterOffset = source.selectedRange.location
                let restored = StudyWorkspace()
                try restored.restore(workspace.archive())
                try await settle(restored.readers[0]); try await settle(restored.readers[1])
                #expect(restored.readers[1].page?.destination.ordinal == article.sectionOrdinal)
                #expect(restored.readers[1].isCommentary && restored.readers[1].commentarySourceID == restored.readers[0].id)
                restored.closeAll()
            }
            workspace.closeAll()
        }
    }

}
