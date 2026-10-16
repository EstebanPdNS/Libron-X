import Foundation
@testable import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct ReaderLinkRoutingTests {
    private func resource(_ name: String) -> LibraryResource {
        .init(location: URL(fileURLWithPath: "/authored/" + name + ".LSF"), title: name, byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
    }
    private func bible(_ resource: LibraryResource) -> ReaderSession {
        let reader = ReaderSession(resource: resource, loader: { _, destination in
            .init(destination: destination, text: "Accepted passage", sectionCount: 1)
        })
        let anchor = LegacyReferenceAnchor(reference: "Ge 1:1", flags: 0, dataTypeCode: 0, characterOffset: 0, decodedOffset: 0)
        let content = LegacySectionContent(descriptor: .init(ordinal: 0, headerOffset: 0, payloadOffset: 0, storedLength: 0,
            decodedLength: 0, mode: 0, codecWord: nil), plainText: "Authored verse", runs: [], expectedCharacterCount: 14,
            recognizedFormat: "authored", paragraphs: [], anchors: [anchor], markers: [], graphics: [], warnings: [], paragraphDocuments: nil)
        reader.page = .init(destination: .init(ordinal: 0, reference: "Ge 1:1"), text: content.plainText, sectionCount: 1, content: content)
        return reader
    }
    private func link(_ attribute: String) throws -> LegacyInlineLink {
        .init(range: .init(location: 0, length: 2), label: "12", sourceName: attribute,
              target: .bible(try #require(LegacyBibleLinkReference.parse(attribute))))
    }
    @Test func explicitBibleTargetIsUsedWithoutOverridingAnEditionRequestedByTheSource() throws {
        let workspace = StudyWorkspace(), source = bible(resource("RVR95")), target = bible(resource("RVR60"))
        workspace.readers = [source, target]; workspace.readerOrder = [source.id, target.id]
        workspace.resources = [source.resource, target.resource]; workspace.referenceTargetID = target.id
        #expect(try workspace.resourceForInlineLink(link("=rGe 4:12"), source: source.resource) == target.resource)
        #expect(try workspace.resourceForInlineLink(link("=rGe 4:12(RVR95)"), source: source.resource) == source.resource)
        #expect(throws: RebuildError.self) { try workspace.resourceForInlineLink(link("=rGe 4:12(Missing)"), source: source.resource) }
        let note = LegacyInlineLink(range: .init(location: 0, length: 1), label: "a", sourceName: "note.a", sectionOrdinal: 7)
        #expect(try workspace.resourceForInlineLink(note, source: source.resource) == source.resource)
    }
    @Test func nativeContextActionsRouteTheSameTypedDestinationAndResourceWithoutLoadingAPreview() throws {
        let source = resource("RVR60"), target = resource("RVR95"), controller = ReaderLinkPreviewController()
        controller.resource = source; controller.resolveResource = { _, _ in target }
        var received: [(LibraryResource, ReaderDestination, Bool)] = []
        controller.onOpen = { received.append(($0, $1, $2)) }
        controller.openSourceLink(try link("=rGe 4:12-14(RVR95)"), newReader: true, window: nil)
        #expect(received.count == 1 && received[0].0 == target && received[0].2)
        #expect(received[0].1.reference == "Ge 4:12" && received[0].1.endReference == "Ge 4:14" && received[0].1.requiredEdition == "RVR95")
    }
    @Test func missingBibleIsAnExplicitErrorAndLocalArticlesStillResolve() throws {
        let workspace = StudyWorkspace(), source = resource("Commentary")
        #expect(throws: RebuildError.self) { try workspace.resourceForInlineLink(link("=rGe 4:12"), source: source) }
        let local = LegacyInlineLink(range: .init(location: 0, length: 1), label: "a", sourceName: "note.a", sectionOrdinal: 5)
        #expect(try workspace.resourceForInlineLink(local, source: source) == source)
    }
    @Test func openingInTheTargetPreservesTheSourceAndCommitsTheFullRequestedPassage() async throws {
        let workspace = StudyWorkspace(), source = bible(resource("RVR95")), target = bible(resource("RVR60"))
        workspace.readers = [source, target]; workspace.readerOrder = [source.id, target.id]; workspace.referenceTargetID = target.id
        let destination = try ReaderLinkPreviewState.destination(for: link("=rGe 4:12-14"), resource: target.resource)
        workspace.openInlineLink(target.resource, destination: destination, from: source, newReader: false)
        for _ in 0..<100 where target.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(workspace.readers.count == 2 && workspace.activeReader === target)
        #expect(target.page?.destination.endReference == "Ge 4:14" && target.history == [destination])
        #expect(source.page?.text == "Authored verse" && source.history.isEmpty)
        // Opening a note temporarily removes visible anchors but retains the
        // established capability of this same resource for later reference links.
        target.page = .init(destination: .init(ordinal: 0), text: "Authored note", sectionCount: 1)
        #expect(target.hasObservedBible && !target.canSynchronizeBible)
    }
}
