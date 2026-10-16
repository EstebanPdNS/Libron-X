import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct WindowLinkCommandTests {
    private func workspace(_ fixture: AuthoredReaderFixture) -> StudyWorkspace {
        StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")),
            resourceVisibility: LibraryResourceVisibility(url: fixture.root.appendingPathComponent("hidden.json")))
    }
    private func page(_ fixture: AuthoredReaderFixture) throws -> ReaderPage {
        let base = try LegacyContentReader.readSection(lsfURL: fixture.resources[0].location, ordinal: 0)
        let anchors = [0, 7, 15].enumerated().map { index, offset in
            LegacyReferenceAnchor(reference: "bible+rvr60.1.4.\(index + 1)", flags: 0, dataTypeCode: 16,
                characterOffset: offset, decodedOffset: UInt64(offset), referenceFormatFlags: 0)
        }
        let content = LegacySectionContent(descriptor: base.descriptor, plainText: base.plainText, runs: base.runs,
            expectedCharacterCount: base.expectedCharacterCount, recognizedFormat: base.recognizedFormat,
            paragraphs: base.paragraphs, anchors: anchors, markers: [], graphics: [], warnings: [], paragraphDocuments: nil)
        return .init(destination: .init(ordinal: 0), text: content.plainText, sectionCount: 1, content: content)
    }
    @Test func allSixCommandGroupsSynchronizeOnlyTheirOwnReadersAndCanBeCleared() throws {
        let fixture = try AuthoredReaderFixture(documents: [["First.\nSecond.\nThird."]]); defer { fixture.remove() }
        let workspace = workspace(fixture), page = try page(fixture)
        var pairs: [[ReaderSession]] = []
        for group in ReaderLinkGroup.allCases where group != .none {
            let pair = (0..<2).map { _ in workspace.open(fixture.resources[0], startReading: false) }
            for reader in pair {
                reader.page = page; reader.visibleBibleReference = "Ge 4:1"
                workspace.activate(reader); #expect(workspace.canLinkActiveReader)
                workspace.setActiveLinkGroup(group, selected: true)
            }
            pairs.append(pair)
        }
        #expect(workspace.readers.count == 12)
        for (index, pair) in pairs.enumerated() {
            pair[0].observeBiblePosition(7, fromViewport: true)
            #expect(pair[1].currentReference == "Ge 4:2")
            for untouched in pairs.dropFirst(index + 1) { #expect(untouched.allSatisfy { $0.currentReference == "Ge 4:1" }) }
        }
        workspace.clearLinks()
        pairs[0][0].observeBiblePosition(15, fromViewport: true)
        #expect(workspace.readers.allSatisfy { $0.linkGroup == .none })
        #expect(pairs[0][1].currentReference == "Ge 4:2")
    }
    @Test func checkedGroupCanDetachAndStaleUncheckedEventDoesNotClearANewGroup() throws {
        let fixture = try AuthoredReaderFixture(documents: [["First.\nSecond.\nThird."]]); defer { fixture.remove() }
        let workspace = workspace(fixture), reader = workspace.open(fixture.resources[0], startReading: false)
        reader.page = try page(fixture)
        workspace.setActiveLinkGroup(.a, selected: true)
        workspace.setActiveLinkGroup(.b, selected: true)
        workspace.setActiveLinkGroup(.a, selected: false)
        #expect(reader.linkGroup == .b)
        workspace.setActiveLinkGroup(.b, selected: false)
        #expect(reader.linkGroup == .none)
        workspace.setActiveLinkGroup(.none, selected: false)
        #expect(reader.linkGroup == .none)
    }
    @Test func repeatedGroupAssignmentDoesNotMoveAReaderOrReapplySelection() throws {
        let fixture = try AuthoredReaderFixture(documents: [["First.\nSecond.\nThird."]]); defer { fixture.remove() }
        let workspace = workspace(fixture), page = try page(fixture)
        let leader = workspace.open(fixture.resources[0], startReading: false)
        let reader = workspace.open(fixture.resources[0], startReading: false)
        for item in [leader, reader] { item.page = page; item.visibleBibleReference = "Ge 4:1"; workspace.setLinkGroup(.a, for: item) }
        reader.visibleBibleReference = "Ge 4:3"
        let revision = reader.selectionRequest
        workspace.setLinkGroup(.a, for: reader)
        #expect(reader.currentReference == "Ge 4:3" && reader.selectionRequest == revision && !reader.isLoading)
    }
    @Test func targetSettersAreIdempotentAndClosedReadersCannotStealOrClearAnotherTarget() throws {
        let fixture = try AuthoredReaderFixture(documents: [["First."]]); defer { fixture.remove() }
        let workspace = workspace(fixture)
        let first = workspace.open(fixture.resources[0], startReading: false)
        let second = workspace.open(fixture.resources[0], startReading: false)
        workspace.setReferenceTarget(true, for: first); workspace.setReferenceTarget(true, for: first)
        #expect(workspace.referenceTargetID == first.id)
        workspace.setReferenceTarget(false, for: second); #expect(workspace.referenceTargetID == first.id)
        workspace.setReferenceTarget(true, for: second); workspace.close(first)
        workspace.toggleReferenceTarget(first); workspace.setReferenceTarget(false, for: first)
        workspace.setLinkGroup(.f, for: first)
        #expect(workspace.referenceTargetID == second.id && first.linkGroup == .none)
        workspace.toggleReferenceTarget(second); #expect(workspace.referenceTargetID == nil)
        workspace.toggleReferenceTarget(second); workspace.close(second)
        #expect(workspace.referenceTargetID == nil)
    }
    @Test func unindexedReadersCannotStartLinkingButKnownIndexedResourcesCanDetachOnANote() throws {
        let fixture = try AuthoredReaderFixture(documents: [["First.\nSecond.\nThird."]]); defer { fixture.remove() }
        let workspace = workspace(fixture), reader = workspace.open(fixture.resources[0], startReading: false)
        #expect(!workspace.canLinkActiveReader)
        workspace.setActiveLinkGroup(.f, selected: true); #expect(reader.linkGroup == .none)
        reader.page = try page(fixture); workspace.setActiveLinkGroup(.f, selected: true)
        reader.page = .init(destination: .init(ordinal: 0), text: "Unindexed note", sectionCount: 1)
        #expect(!reader.canSynchronizeBible && reader.hasObservedBible && workspace.canLinkActiveReader)
        workspace.setActiveLinkGroup(.none, selected: true); #expect(reader.linkGroup == .none)
        workspace.closeAll(); #expect(!workspace.canLinkActiveReader)
        workspace.setActiveLinkGroup(.a, selected: true); #expect(workspace.readers.isEmpty)
    }
}
