import AppKit
import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct BibleSynchronizationTests {
    private func settle(_ readers: [ReaderSession]) async throws {
        for _ in 0..<1000 {
            if readers.allSatisfy({ !$0.isLoading }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Linked readers did not settle")
    }
    private func page(_ fixture: AuthoredReaderFixture, ordinal: Int = 0, reference: String? = nil) throws -> ReaderPage {
        let base = try LegacyContentReader.readSection(lsfURL: fixture.resources[0].location, ordinal: 0)
        let anchors = [0, 7, 15].enumerated().map { index, offset in
            LegacyReferenceAnchor(reference: "bible+rvr60.1.4.\(index + 1)", flags: 0, dataTypeCode: 16,
                                  characterOffset: offset, decodedOffset: UInt64(offset), referenceFormatFlags: 0)
        }
        let content = LegacySectionContent(descriptor: base.descriptor, plainText: base.plainText, runs: base.runs,
            expectedCharacterCount: base.expectedCharacterCount, recognizedFormat: base.recognizedFormat,
            paragraphs: base.paragraphs, anchors: anchors, markers: [], graphics: [], warnings: [], paragraphDocuments: nil)
        return .init(destination: .init(ordinal: ordinal, reference: reference), text: content.plainText, sectionCount: 100, content: content)
    }
    @Test func fourReadersFollowEitherSourceInPlaceWithoutFeedbackOrAdditionalReads() throws {
        let fixture = try AuthoredReaderFixture(documents: [["First.\nSecond.\nThird."]]); defer { fixture.remove() }
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")))
        let readers = (0..<4).map { _ in workspace.open(fixture.resources[0], startReading: false) }
        for (i, reader) in readers.enumerated() { reader.page = try page(fixture, ordinal: i * 11); reader.visibleBibleReference = "Ge 4:1" }
        workspace.synchronizeBibles(from: readers[0])
        #expect(readers.allSatisfy { $0.linkGroup == .a && $0.currentReference == "Ge 4:1" })
        let revisions = readers.map(\.selectionRequest)
        readers[2].observeBiblePosition(15, fromViewport: true)
        #expect(readers.allSatisfy { $0.currentReference == "Ge 4:3" })
        #expect(readers[2].viewportCharacterOffset == 15)
        for (i, reader) in readers.enumerated() {
            #expect(reader.page?.destination.ordinal == i * 11 && reader.history.isEmpty && !reader.isLoading)
            #expect(reader.selectionRequest == revisions[i] + (i == 2 ? 0 : 1))
        }
        // Repeated notifications inside the same verse produce no echo.
        let after = readers.map(\.selectionRequest)
        readers[2].observeBiblePosition(17, fromViewport: true)
        #expect(readers.map(\.selectionRequest) == after)
        workspace.setLinkGroup(.none, for: readers[3])
        readers[0].observeBiblePosition(7, fromViewport: true)
        #expect(readers.prefix(3).allSatisfy { $0.currentReference == "Ge 4:2" })
        #expect(readers[3].currentReference == "Ge 4:3")
        workspace.clearLinks(); readers[0].observeBiblePosition(0, fromViewport: true)
        #expect(readers[1].currentReference == "Ge 4:2")
    }
    @Test func joiningAnotherGroupAlignsImmediatelyAndGroupsRemainIndependent() throws {
        let fixture = try AuthoredReaderFixture(documents: [["First.\nSecond.\nThird."]]); defer { fixture.remove() }
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")))
        let readers = (0..<4).map { _ in workspace.open(fixture.resources[0], startReading: false) }
        for reader in readers { reader.page = try page(fixture); reader.visibleBibleReference = "Ge 4:1" }
        workspace.setLinkGroup(.a, for: readers[0]); workspace.setLinkGroup(.a, for: readers[1])
        workspace.setLinkGroup(.b, for: readers[2]); workspace.setLinkGroup(.b, for: readers[3])
        readers[0].observeBiblePosition(7, fromViewport: true)
        #expect(readers[1].currentReference == "Ge 4:2" && readers[2].currentReference == "Ge 4:1")
        workspace.setLinkGroup(.a, for: readers[3])
        #expect(readers[3].currentReference == "Ge 4:2")
        readers[2].observeBiblePosition(15, fromViewport: true)
        #expect(readers[3].currentReference == "Ge 4:2")
    }
    @Test func choosingIndividualBiblesLinksOnlyTheSelectedReaders() throws {
        let fixture = try AuthoredReaderFixture(documents: [["First.\nSecond.\nThird."]]); defer { fixture.remove() }
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")))
        let readers = (0..<4).map { _ in workspace.open(fixture.resources[0], startReading: false) }
        for reader in readers { reader.page = try page(fixture); reader.visibleBibleReference = "Ge 4:1" }
        workspace.setBibleLink(true, from: readers[0], to: readers[2])
        readers[0].observeBiblePosition(7, fromViewport: true)
        #expect(readers[2].currentReference == "Ge 4:2")
        #expect(readers[1].linkGroup == .none && readers[3].linkGroup == .none && readers[1].currentReference == "Ge 4:1")
        workspace.setBibleLink(true, from: readers[0], to: readers[3])
        #expect(readers[3].currentReference == "Ge 4:2")
        workspace.setBibleLink(false, from: readers[0], to: readers[2])
        readers[0].observeBiblePosition(15, fromViewport: true)
        #expect(readers[2].currentReference == "Ge 4:2" && readers[3].currentReference == "Ge 4:3")
    }
    @Test func selectingTextAfterReferenceNavigationRetainsTheReadingViewportForSaving() throws {
        let fixture = try AuthoredReaderFixture(documents: [["First.\nSecond.\nThird."]]); defer { fixture.remove() }
        let workspace = StudyWorkspace()
        let reader = workspace.open(fixture.resources[0], startReading: false)
        let page = try page(fixture)
        reader.page = page; reader.flowPages = [page]; reader.visibleBibleReference = "Ge 4:1"
        reader.followBibleReference("Ge 4:2")
        #expect(reader.viewportCharacterOffset == 7)
        reader.selectFlowPage(page, selection: .init(location: 1, length: 3))
        #expect(reader.currentReference == "Ge 4:2" && reader.viewportCharacterOffset == 7)
        let saved = workspace.archive()
        #expect(saved.panes[0].viewportOffset == 7 && saved.panes[0].selection == .init(location: 1, length: 3))
    }
    @Test func supersededUncooperativeLoadsCannotOverwriteTheNewestPassageAndFailuresRetainText() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["First.\nSecond.\nThird."]]); defer { fixture.remove() }
        let base = try page(fixture)
        let reader = ReaderSession(resource: fixture.resources[0], loader: { _, destination in
            let slow = destination.reference == "Jn 1:1"
            try? await Task.sleep(for: .milliseconds(slow ? 80 : 5))
            if destination.reference == "Ge 999:1" { throw RebuildError.referenceNotFound }
            var result = base; result.destination = .init(ordinal: slow ? 10 : 20, reference: destination.reference)
            return result
        })
        reader.followBibleReference("Jn 1:1"); reader.followBibleReference("Re 22:21")
        try await settle([reader]); try await Task.sleep(for: .milliseconds(100))
        #expect(reader.page?.destination.ordinal == 20 && reader.history.count == 1)
        let retained = reader.page?.text
        reader.followBibleReference("Ge 999:1"); try await settle([reader])
        #expect(reader.page?.text == retained && reader.error != nil && reader.history.count == 1)
    }
}

@MainActor struct BibleSynchronizationCorpusTests {
    private var root: URL { get throws { URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"])) } }
    private func resource(_ name: String) throws -> LibraryResource {
        let url = try root.appendingPathComponent(name), modern = name.lowercased().hasSuffix(".lbxlls")
        return .init(location: url, title: name, byteCount: Int64(try LegacyGraphicsService.fileStamp(url).size),
                     format: modern ? .libronixLLS : .legacyLSF, support: .metadataOnly,
                     provenance: modern ? .libronixMetadata : .legacyPublicMetadata)
    }
    private func settle(_ readers: [ReaderSession]) async throws {
        for _ in 0..<3000 {
            if readers.allSatisfy({ !$0.isLoading }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Original Bible navigation did not settle")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"] != nil))
    func originalRV60ReferenceFieldAcceptsFlexibleInputAndKeepsTheExactSourceVerse() async throws {
        let reader = ReaderSession(resource: try resource("rvr60.lbxlls"))
        for raw in ["Génesis 4:1", "Genesis 4.1", "Gen4.1", "Gn 4,1", "Ge.4:1", "GEN. 4 : 1", "Gen 4 1",
                    "Génesis capítulo 4 versículo 1", "Gen cap. 4 v. 1", "Gen 4", "Gen4"] {
            reader.locator = raw; reader.goToReference(); try await settle([reader])
            #expect(reader.error == nil && reader.currentReference == "Ge 4:1" && reader.page?.destination.ordinal == 3801)
            #expect(reader.selectedText.contains("Conoció Adán"))
        }
        let retained = reader.page?.text
        reader.locator = "Gen 4..1"; reader.goToReference()
        #expect(reader.error != nil && reader.page?.text == retained)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"] != nil))
    func suppliedReferenceNavigation() async throws {
        var receipt: [[String: Any]] = []
        for name in ["RVR60.LSF", "rvr60.lbxlls", "RVR95.LSF", "LBLA95.lbxlls", "NVI.lbxlls", "KJV.lbxlls", "ESV.lbxlls", "NCV.lbxlls"] {
            let book = try resource(name), before = try LegacyGraphicsService.fileStamp(book.location)
            for query in ["Génesis 4:1", "Ge 4:3", "Salmos 23:1", "Juan 1:1", "1 Corintios 13:4", "Apocalipsis 22:21"] {
                print("CHECK REFERENCE \(name) \(query)")
                let page = try await ReaderSession.read(book, .init(ordinal: 0, reference: query))
                let expected = try #require(LegacyPassageQuery.parse(query)?.normalizedKey)
                let offset = try #require(page.selection?.location)
                #expect(page.content?.anchors.contains { $0.characterOffset == offset && $0.reference.flatMap { LegacyPassageQuery.sourceReference($0)?.normalizedKey } == expected } == true)
                #expect(page.destination.reference.flatMap { LegacyPassageQuery.parse($0)?.normalizedKey } == expected)
                receipt.append(["file": name, "query": query, "ordinal": page.destination.ordinal, "offset": offset])
            }
            #expect(try LegacyGraphicsService.fileStamp(book.location) == before)
        }
        if let output = ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_RECEIPT"] {
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
        print("Original Bible references: \(receipt.count) verified source anchors across eight editions/formats")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"] != nil))
    func fourOriginalEditionsSynchronizeBothDirectionsAndRestoreTheirLinks() async throws {
        let personal = WorkspacePersonalState(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/personal.json"))
        let workspace = StudyWorkspace(personal: personal)
        let books = try ["rvr60.lbxlls", "RVR95.LSF", "LBLA95.lbxlls", "NVI.lbxlls"].map(resource)
        workspace.resources = books
        let readers = books.map { workspace.open($0, startReading: false) }
        for reader in readers { reader.load(.init(ordinal: 0, reference: "Ge 4:1"), propagateReference: false) }
        try await settle(readers)
        #expect(readers.allSatisfy { $0.error == nil && $0.currentReference == "Ge 4:1" })
        workspace.synchronizeBibles(from: readers[0])
        readers[0].locator = "Juan 1:1"; readers[0].goToReference(); try await settle(readers)
        #expect(readers.allSatisfy { $0.error == nil && LegacyPassageQuery.parse($0.currentReference ?? "")?.normalizedKey == "jn 1:1" })
        #expect(Set(readers.compactMap { $0.page?.destination.ordinal }).count > 1)
        readers[3].locator = "Génesis 4:1"; readers[3].goToReference(); try await settle(readers)
        #expect(readers.allSatisfy { $0.error == nil && $0.currentReference == "Ge 4:1" })
        let thirdVerse = try #require(readers[0].page?.content?.anchors.first { $0.reference.flatMap { LegacyPassageQuery.sourceReference($0)?.normalizedKey } == "ge 4:3" })
        readers[0].observeBiblePosition(thirdVerse.characterOffset, fromViewport: true); try await settle(readers)
        #expect(readers.allSatisfy { $0.currentReference == "Ge 4:3" })
        let saved = try JSONDecoder().decode(WorkspaceArchive.self, from: JSONEncoder().encode(workspace.archive()))
        let restored = StudyWorkspace(personal: personal); try restored.restore(saved); try await settle(restored.readers)
        #expect(restored.readers.count == 4 && restored.readers.allSatisfy { $0.linkGroup == .a && $0.currentReference == "Ge 4:3" && $0.error == nil })
        print("Four original Bible panes: two-way navigation, in-page verse tracking, independent physical ordinals, persisted group A")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"] != nil))
    func allSerializedBookIDsAgreeWithPairedOriginalSourceLabels() async throws {
        let modern = try await LibronixBookService.shared.prepare(resource("rvr60.lbxlls"))
        let classic = try resource("RVR60.LSF")
        let a = try LegacyContentReader.inspectSections(lsfURL: modern.location), b = try LegacyContentReader.inspectSections(lsfURL: classic.location)
        #expect(a.sections.count == b.sections.count)
        var books = Set<String>(), paired = 0
        for ordinal in a.sections.indices {
            let left = try LegacyContentReader.readSection(lsfURL: modern.location, descriptor: a.sections[ordinal], tartEnd: a.tartOffset + a.tartLength)
            guard left.anchors.contains(where: { $0.reference?.hasPrefix("bible+") == true }) else { continue }
            let right = try LegacyContentReader.readSection(lsfURL: classic.location, descriptor: b.sections[ordinal], tartEnd: b.tartOffset + b.tartLength)
            let sourceKeys = right.anchors.compactMap { $0.reference.flatMap(LegacyPassageQuery.sourceReference) }
            for anchor in left.anchors {
                guard let raw = anchor.reference, raw.hasPrefix("bible+"), let parsed = LegacyPassageQuery.parse(raw) else { continue }
                // The editions have slightly different zero-width characters;
                // their UTF16 offsets are edition-local and must never be copied.
                // Compare source labels in the corresponding physical article.
                let source = try #require(sourceKeys.first { $0.chapter == parsed.chapter && $0.verse == parsed.verse },
                    "Missing paired source label ordinal=\(ordinal) raw=\(raw)")
                #expect(source.sourceBookKey == parsed.sourceBookKey)
                books.insert(parsed.sourceBookKey); paired += 1
            }
        }
        #expect(books.count == 66 && paired >= 31_000)
        print("Serialized Bible identifier mapping: \(paired) matching original anchors; \(books.count) books; edition-local UTF16 offsets retained")
    }
}

@MainActor struct BibleViewportTests {
    @Test func readerKeepsFloatingScrollerWithoutReservingALegacyTrack() throws {
        _ = NSApplication.shared
        let scroll = ReaderScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = ReaderScroller()
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1800))
        // AppKit can reapply this preference after the initial configuration.
        scroll.scrollerStyle = .legacy
        scroll.tile()
        #expect(scroll.scrollerStyle == .overlay && scroll.verticalScroller?.scrollerStyle == .overlay)
        #expect(abs(scroll.contentView.frame.width - scroll.bounds.width) < 0.5)
        #expect(ReaderScroller.isCompatibleWithOverlayScrollers)
    }
    @Test func aligningVisibleAndFinalVersesMovesTheirLineToTheTop() throws {
        _ = NSApplication.shared
        let scroll = ReaderScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        let text = ActiveTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        scroll.hasVerticalScroller = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        text.font = NSFont.systemFont(ofSize: 18)
        text.string = (1...20).map { "Authored verse \($0)\n" }.joined()
        scroll.documentView = ReaderDocumentView(textView: text)
        let layout = try #require(text.layoutManager), container = try #require(text.textContainer)
        layout.ensureLayout(for: container)
        for verse in [2, 12, 20] {
            let offset = (text.string as NSString).range(of: "Authored verse \(verse)\n").location
            let glyph = layout.glyphIndexForCharacter(at: offset)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            text.alignCharacterToTop(offset, in: scroll)
            #expect(scroll.contentInsets.bottom == 0)
            #expect(scroll.verticalScroller?.frame.height ?? 0 > scroll.frame.height * 0.9)
            #expect(abs(scroll.documentVisibleRect.minY - (text.textContainerOrigin.y + line.minY)) < 1,
                    "Verse \(verse) should align even if already visible or last in the article; visible=\(scroll.documentVisibleRect) line=\(line)")
        }
    }
    @Test func newOneHundredPercentIsTheFormerOneHundredFiftyPercent() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Comfortable default"]]); defer { fixture.remove() }
        let reader = ReaderSession(resource: fixture.resources[0])
        #expect(reader.textScale == 1 && reader.renderingScale == 1.5)
        let baseline = ReaderTypography.render(text: "Sample", content: nil, typography: nil).text
        let display = ReaderTypography.render(text: "Sample", content: nil, typography: nil, scale: reader.renderingScale).text
        let original = try #require(baseline.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let larger = try #require(display.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(abs(larger.pointSize - original.pointSize * 1.5) < 0.01)
        #expect(ReaderOEBViewport(zoom: reader.renderingScale).zoom == 1.5)
    }
    @Test func invisibleOriginalBoundaryMarkersDoNotAlignThePrecedingVerse() {
        let text = "Previous verse\n\u{FEFF}\u{200B}12\u{FEFF}Actual verse" as NSString
        let anchor = "Previous verse".utf16.count
        let visible = ActiveTextView.visibleCharacter(in: text, at: anchor)
        #expect(text.substring(from: visible).hasPrefix("12"))
        #expect(visible == anchor + 3)
        #expect(ActiveTextView.visibleCharacter(in: "😀Alpha" as NSString, at: 0) == 0)
    }
}
