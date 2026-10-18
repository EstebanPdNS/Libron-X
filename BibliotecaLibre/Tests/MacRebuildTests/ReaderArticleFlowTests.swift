import AppKit
import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct ReaderArticleFlowTests {
    private func pages(_ fixture: AuthoredReaderFixture) throws -> [ReaderPage] {
        try (0..<8).map { ordinal in
            let source = try LegacyContentReader.readSection(lsfURL: fixture.resources[0].location, ordinal: ordinal)
            let anchor = LegacyReferenceAnchor(reference: "Ge 1:\(ordinal + 1)", flags: 0, dataTypeCode: 16,
                characterOffset: 0, decodedOffset: 0, referenceFormatFlags: 0)
            let content = LegacySectionContent(descriptor: source.descriptor, plainText: source.plainText, runs: source.runs,
                expectedCharacterCount: source.expectedCharacterCount, recognizedFormat: source.recognizedFormat,
                paragraphs: source.paragraphs, anchors: [anchor], markers: [], graphics: [], warnings: [], paragraphDocuments: nil)
            return ReaderPage(destination: .init(ordinal: ordinal, reference: "Ge 1:\(ordinal + 1)"), text: source.plainText,
                sectionCount: 8, content: content)
        }
    }
    private func wait(_ reader: ReaderSession) async throws {
        for _ in 0..<1000 {
            if !reader.isLoading && reader.flowTask == nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Reader flow did not settle")
    }
    @Test func prefetchRetainsCompleteSourceArticlesAndContinuesInBothDirections() async throws {
        let fixture = try AuthoredReaderFixture(documents: [(1...8).map { "Article \($0)" }]); defer { fixture.remove() }
        let pages = try pages(fixture)
        let reader = ReaderSession(resource: fixture.resources[0], loader: { _, destination in pages[destination.ordinal] })
        reader.load(.init(ordinal: 2)); try await wait(reader)
        reader.startReadingFlow(); try await wait(reader)
        #expect(reader.flowPages.map { $0.destination.ordinal } == [1, 2, 3, 4, 5, 6])
        #expect(reader.flowPages.allSatisfy { $0.text == pages[$0.destination.ordinal].text && $0.content == pages[$0.destination.ordinal].content })
        let count = reader.selectionRequest
        reader.observeFlowPage(5, offset: 0); try await wait(reader)
        #expect(reader.page?.destination.ordinal == 5 && reader.currentReference == "Ge 1:6")
        #expect(reader.flowPages.map { $0.destination.ordinal } == [4, 5, 6, 7])
        #expect(reader.selectionRequest == count)
        reader.followBibleReference("Ge 1:5"); try await wait(reader)
        #expect(reader.page?.destination.ordinal == 4 && reader.selectedRange.location == 0)
        #expect(reader.selectionRequest == count + 1)
        reader.cancel()
    }
    @Test func selectionAndClicksNeverNavigateLinkedReadersOrChangeTheViewportReference() async throws {
        let fixture = try AuthoredReaderFixture(documents: [(1...8).map { "Article \($0)" }]); defer { fixture.remove() }
        let pages = try pages(fixture), workspace = StudyWorkspace()
        let reader = ReaderSession(resource: fixture.resources[0], loader: { _, destination in pages[destination.ordinal] })
        let peer = ReaderSession(resource: fixture.resources[0], loader: { _, destination in
            let index = destination.reference.flatMap(LegacyPassageQuery.sourceReference).map { $0.verse - 1 } ?? destination.ordinal
            return pages[index]
        })
        workspace.readers = [reader, peer]; workspace.connect(reader); workspace.connect(peer)
        reader.load(.init(ordinal: 0)); peer.load(.init(ordinal: 0)); try await wait(reader); try await wait(peer)
        reader.startReadingFlow(); try await wait(reader)
        reader.linkGroup = .a; peer.linkGroup = .a
        let revision = peer.selectionRequest, location = peer.page?.destination
        reader.selectFlowPage(pages[2], selection: .init(location: 1, length: 3))
        reader.observeBiblePosition(0) // A selection-origin event is ignored.
        #expect(reader.selectedText == (pages[2].text as NSString).substring(with: .init(location: 1, length: 3)))
        #expect(reader.currentReference == "Ge 1:1")
        #expect(peer.page?.destination == location && peer.selectionRequest == revision && peer.currentReference == "Ge 1:1")
        reader.observeFlowPage(2, offset: 0); try await wait(peer)
        #expect(peer.currentReference == "Ge 1:3")
        reader.cancel(); peer.cancel()
    }
    @Test func explicitPassagesAndNonBibleArticlesDoNotAppendUnrelatedInternalContent() async throws {
        let fixture = try AuthoredReaderFixture(documents: [(1...8).map { "Article \($0)" }]); defer { fixture.remove() }
        var pages = try pages(fixture)
        let end = pages[0]; pages[0].destination.endReference = "Ge 1:2"
        let reader = ReaderSession(resource: fixture.resources[0], loader: { [pages] _, destination in pages[destination.ordinal] })
        reader.load(.init(ordinal: 0)); try await wait(reader); reader.startReadingFlow(); try await wait(reader)
        #expect(reader.flowPages.count == 1)
        var unanchored = end; unanchored.content = nil
        #expect(!ReaderSession.flowContinues(from: end, to: unanchored))
        #expect(!ReaderSession.flowContinues(from: end, to: end))
    }
    @Test func nativeArticleFramesAreContiguousAndSelectionRemainsSourceLocal() throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [(1...8).map { "Article \($0)" }]); defer { fixture.remove() }
        let pages = try pages(fixture), reader = ReaderSession(resource: fixture.resources[0]), workspace = StudyWorkspace()
        reader.page = pages[0]; reader.flowPages = Array(pages.prefix(3))
        let coordinator = ReaderArticleFlowView.Coordinator(reader: reader, workspace: workspace)
        let scroll = ReaderScrollView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        let document = ReaderArticleFlowView.FlowDocument(); scroll.documentView = document
        coordinator.scroll = scroll; coordinator.document = document
        coordinator.update()
        let surfaces = try (0..<3).map { try #require(coordinator.surfaces[$0]) }
        #expect(surfaces.map { $0.view.string } == pages.prefix(3).map(\.text))
        #expect(abs(surfaces[0].view.frame.maxY - surfaces[1].view.frame.minY) < 0.1)
        #expect(abs(surfaces[1].view.frame.maxY - surfaces[2].view.frame.minY) < 0.1)
        #expect(surfaces[0].view.frame.height < 100 && surfaces[1].view.frame.height < 100)
        surfaces[1].delegate.onSelection(.init(location: 2, length: 2))
        #expect(reader.page?.destination.ordinal == 1 && reader.selectedRange == .init(location: 2, length: 2))
    }
    @Test func actualClipMovementFollowsAcrossBufferedChaptersAndBackWithoutWheelCallbacks() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [(1...8).map { "Article \($0)" }]); defer { fixture.remove() }
        let pages = try pages(fixture), reader = ReaderSession(resource: fixture.resources[0]), workspace = StudyWorkspace()
        reader.page = pages[0]; reader.flowPages = Array(pages.prefix(3)); reader.visibleBibleReference = "Ge 1:1"
        let coordinator = ReaderArticleFlowView.Coordinator(reader: reader, workspace: workspace)
        let scroll = ReaderScrollView(frame: .init(x: 0, y: 0, width: 600, height: 80))
        let document = ReaderArticleFlowView.FlowDocument(); scroll.documentView = document
        coordinator.scroll = scroll; coordinator.document = document
        scroll.onUserScroll = { [weak coordinator] in coordinator?.userScrolled() }
        coordinator.update()
        #expect(coordinator.observation == nil, "Programmatic initial layout must not emit scroll navigation")
        for ordinal in [0, 1, 0, 2, 1] {
            let surface = try #require(coordinator.surfaces[ordinal])
            scroll.contentView.scroll(to: .init(x: 0, y: surface.view.frame.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
            await coordinator.observation?.value
            #expect(reader.page?.destination.ordinal == ordinal && reader.currentReference == "Ge 1:\(ordinal + 1)")
            coordinator.update()
        }
        reader.cancel()
    }
    @Test func commentaryAdvancesPastAnOpeningLineBeforeTheVisibleVerseEndsAndReversesOnUpwardScroll() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [(1...8).map { "Article \($0) with authored continuing text.\nA second line remains visible.\nA third line." }]); defer { fixture.remove() }
        var pages = try pages(fixture)
        for ordinal in [0, 2] {
            var link = LegacyInlineLink(range: .init(location: 0, length: 1), label: "Authored note", sourceName: "authored", sectionOrdinal: ordinal + 4)
            link.role = .studyCommentary; pages[ordinal].inlineLinks = [link]
        }
        let reader = ReaderSession(resource: fixture.resources[0]), workspace = StudyWorkspace()
        reader.page = pages[0]; reader.flowPages = Array(pages.prefix(3)); reader.visibleBibleReference = "Ge 1:1"
        let coordinator = ReaderArticleFlowView.Coordinator(reader: reader, workspace: workspace)
        let scroll = ReaderScrollView(frame: .init(x: 0, y: 0, width: 600, height: 100))
        let document = ReaderArticleFlowView.FlowDocument(); scroll.documentView = document
        coordinator.scroll = scroll; coordinator.document = document; coordinator.update()
        let first = try #require(coordinator.surfaces[0]), layout = try #require(first.view.layoutManager)
        let y = first.view.textContainerOrigin.y + layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY
        var followed: [String] = []; reader.onReadingPositionChange = { followed.append($0) }
        for (top, expected) in [(y, "Ge 1:1"), (y + 4, "Ge 1:3"), (y + 15, "Ge 1:3"), (y, "Ge 1:1")] {
            scroll.contentView.scroll(to: .init(x: 0, y: top))
            coordinator.userScrolled(); await coordinator.observation?.value
            #expect(reader.currentReference == "Ge 1:1", "The verse body is still visible")
            #expect(reader.commentaryViewportReference == expected && followed.last == expected)
        }
        reader.cancel()
    }
    @Test func repeatedChapterReferenceWaitsForTheActualVerseOpeningLine() throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [(1...8).map { _ in "Chapter heading\n1 First verse with note a.\n2 Second verse with note b." }]); defer { fixture.remove() }
        var page = try pages(fixture)[0]
        let source = try #require(page.content), text = page.text as NSString
        let first = text.range(of: "1 First").location, second = text.range(of: "2 Second").location
        let anchors = [(0, "Ge 1:1"), (first, "Ge 1:1"), (second, "Ge 1:2")].map { offset, reference in
            LegacyReferenceAnchor(reference: reference, flags: 0, dataTypeCode: 16,
                characterOffset: offset, decodedOffset: UInt64(offset), referenceFormatFlags: 0)
        }
        page.content = LegacySectionContent(descriptor: source.descriptor, plainText: source.plainText, runs: source.runs,
            expectedCharacterCount: source.expectedCharacterCount, recognizedFormat: source.recognizedFormat,
            paragraphs: source.paragraphs, anchors: anchors, markers: [], graphics: [], warnings: [], paragraphDocuments: nil)
        page.inlineLinks = ["a.", "b."].enumerated().map { ordinal, label in
            var link = LegacyInlineLink(range: text.range(of: label), label: label, sourceName: "authored", sectionOrdinal: ordinal + 4)
            link.role = .studyCommentary; return link
        }
        let reader = ReaderSession(resource: fixture.resources[0]), workspace = StudyWorkspace()
        reader.page = page; reader.flowPages = [page]
        let coordinator = ReaderArticleFlowView.Coordinator(reader: reader, workspace: workspace)
        let scroll = ReaderScrollView(frame: .init(x: 0, y: 0, width: 600, height: 40))
        let document = ReaderArticleFlowView.FlowDocument(); scroll.documentView = document
        coordinator.scroll = scroll; coordinator.document = document; coordinator.update()
        let surface = try #require(coordinator.surfaces[0]), layout = try #require(surface.view.layoutManager)
        let firstGlyph = layout.glyphIndexForCharacter(at: first)
        let y = surface.view.textContainerOrigin.y + layout.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil).minY
        #expect(surface.commentaryPositions.map(\.offset) == [first, second])
        scroll.contentView.scroll(to: .init(x: 0, y: y - 4))
        #expect(coordinator.nextCommentaryReference() == "Ge 1:1")
        scroll.contentView.scroll(to: .init(x: 0, y: y + 4))
        #expect(coordinator.nextCommentaryReference() == "Ge 1:2")
    }
    @Test func inheritedPrefaceContextIsVerifiedAgainstTheSourceBeforeBufferingOrFollowing() async throws {
        let fixture = try AuthoredReaderFixture(documents: [(1...8).map { "First.\nSecond.\nArticle \($0)" }]); defer { fixture.remove() }
        var pages = try pages(fixture)
        let source = try #require(pages[1].content)
        let anchors = [0, 7].enumerated().map { index, offset in
            LegacyReferenceAnchor(reference: "Ge 1:\(index + 1)", flags: 0, dataTypeCode: 16,
                characterOffset: offset, decodedOffset: UInt64(offset), referenceFormatFlags: 0)
        }
        pages[1].content = LegacySectionContent(descriptor: source.descriptor, plainText: source.plainText, runs: source.runs,
            expectedCharacterCount: source.expectedCharacterCount, recognizedFormat: source.recognizedFormat,
            paragraphs: source.paragraphs, anchors: anchors, markers: [], graphics: [], warnings: [], paragraphDocuments: nil)
        pages[1].destination.reference = "Ge 1:1"
        pages[0].sectionCount = 2; pages[1].sectionCount = 2
        let reader = ReaderSession(resource: fixture.resources[0], loader: { [pages] _, destination in
            pages[destination.reference == nil ? destination.ordinal : 1]
        })
        reader.load(.init(ordinal: 1)); try await wait(reader); reader.startReadingFlow(); try await wait(reader)
        #expect(reader.flowPages.map { $0.destination.ordinal } == [1])
        reader.followBibleReference("Ge 1:1"); try await wait(reader)
        #expect(reader.page?.destination.ordinal == 1)
        reader.load(.init(ordinal: 0)); try await wait(reader)
        reader.followBibleReference("Ge 1:1"); try await wait(reader)
        #expect(reader.page?.destination.ordinal == 1)
        reader.cancel()
    }
    @Test func outOfBodyBoundaryAnchorsAreNotSelectableBiblePositions() {
        let anchors = [-1, 0, 8, 9].enumerated().map { index, offset in
            LegacyReferenceAnchor(reference: "Ge 1:\(index + 1)", flags: 0, dataTypeCode: 16,
                characterOffset: offset, decodedOffset: 0, referenceFormatFlags: 0)
        }
        let index = ReaderBibleIndex(anchors: anchors, textLength: 8)
        #expect(index.references == ["Ge 1:2"] && index.offsets.count == 1)
        #expect(ReaderBibleIndex(anchors: anchors, textLength: 0).entries.isEmpty)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"] != nil))
    func continuousReadingUsesTheSameBoundaryRulesForNineOriginalLSFAndLibronixBibles() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"]))
        var receipt: [[String: Any]] = []
        for name in ["RVR60.LSF", "rvr60.lbxlls", "RVR95.LSF", "LBLA95.lbxlls", "NVI.lbxlls", "KJV.LSF", "KJV.lbxlls", "ESV.lbxlls", "NCV.lbxlls"] {
            let url = root.appendingPathComponent(name), index = url.deletingPathExtension().appendingPathExtension("LIX")
            let resource = LibraryResource(location: url, indexLocation: FileManager.default.fileExists(atPath: index.path) ? index : nil,
                title: name, byteCount: 0, format: name.hasSuffix(".LSF") ? .legacyLSF : .libronixLLS,
                support: .metadataOnly, provenance: .fileName)
            let before = try LegacyGraphicsService.fileStamp(url), reader = ReaderSession(resource: resource)
            reader.load(.init(ordinal: 0, reference: "Ge 1:9")); try await wait(reader)
            reader.startReadingFlow(); try await wait(reader)
            #expect(reader.error == nil && reader.flowWarning == nil)
            let flow = reader.readingFlowPages
            let references = Set(flow.flatMap { $0.content?.anchors.compactMap { $0.reference.flatMap(LegacyPassageQuery.sourceReference)?.normalizedKey } ?? [] })
            #expect(references.contains("ge 1:9") && references.contains("ge 1:14"), "\(name): continuation must be ready without a selection or scroll event")
            #expect(flow.count > 1)
            let beginning = try await ReaderSession.read(resource, .init(ordinal: 0, reference: "Ge 1:1"))
            reader.followBibleReference("Ge 1:1"); try await wait(reader)
            if reader.page?.text != beginning.text {
                for (label, page) in [("resolved", beginning), ("buffer-follow", reader.page!)] {
                    print("FLOW BOUNDARY \(name) \(label) ordinal=\(page.destination.ordinal) length=\(page.text.utf16.count) prefix=\(String(page.text.prefix(80)))")
                    print("FLOW ANCHORS \(name) \(label) \(page.content?.anchors.map { "\($0.characterOffset):\($0.reference ?? "nil")" } ?? [])")
                }
            }
            #expect(reader.page?.text == beginning.text && reader.page?.destination.ordinal == beginning.destination.ordinal,
                "\(name): a boundary-only anchor in a preface must not replace the actual Bible article")
            var boundary: [String: Any] = [:]
            if flow.count == 1, let last = flow.last {
                for ordinal in max(0, last.destination.ordinal - 1)...min(last.sectionCount - 1, last.destination.ordinal + 3) {
                    let adjacent = try await ReaderSession.read(resource, .init(ordinal: ordinal))
                    boundary[String(ordinal)] = ["anchors": adjacent.content?.anchors.compactMap(\.reference) ?? [],
                        "characters": adjacent.text.utf16.count, "prefix": String(adjacent.text.prefix(180)),
                        "title": adjacent.entries.first(where: { $0.ordinal == ordinal })?.title ?? ""]
                }
            }
            for (previous, next) in zip(flow, flow.dropFirst()) { #expect(ReaderSession.flowContinues(from: previous, to: next)) }
            #expect(try LegacyGraphicsService.fileStamp(url) == before)
            receipt.append(["file": name, "physicalArticles": flow.map { $0.destination.ordinal },
                "hasVerse9": references.contains("ge 1:9"), "hasVerse14": references.contains("ge 1:14"), "sourceUnchanged": true,
                "boundaryInspection": boundary])
            reader.cancel()
        }
        if let path = ProcessInfo.processInfo.environment["LIBRONX_FLOW_RECEIPT"] {
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        print("Continuous source reading: nine original Bibles; Ge 1:9 and Ge 1:14 ready without clicking; source-local article boundaries retained")
    }
}
