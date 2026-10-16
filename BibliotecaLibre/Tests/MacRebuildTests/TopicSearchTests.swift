import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct TopicSearchTests {
    @Test func scopesUseExactVisibleIdentityAndNeverFallBackToTheWholeLibrary() {
        let first = resource("same.LSF"), second = resource("same.lbxlls", format: .libronixLLS)
        let unsupported = resource("other.lbxobk", format: .libronixOEB)
        #expect(TopicResourceScope.library.resources(in: [first, second, unsupported]) == [first, second])
        #expect(TopicResourceScope.resource(second.id).resources(in: [first, second]) == [second])
        #expect(TopicResourceScope.resource(second.id).resources(in: [first]).isEmpty)
        #expect(TopicResourceScope.resource(unsupported.id).resources(in: [unsupported]).isEmpty)
    }
    private func resource(_ name: String, format: ResourceFormat = .legacyLSF) -> LibraryResource {
        .init(location: URL(fileURLWithPath: "/authored/" + name), title: name, byteCount: 0,
              format: format, support: .metadataOnly, provenance: .fileName)
    }
    private func entries(_ titles: [String], fixture: AuthoredReaderFixture) throws -> [LegacyArticleDirectoryEntry] {
        let section = try LegacyContentReader.readSection(lsfURL: fixture.resources[0].location, ordinal: 0).descriptor
        return titles.enumerated().map { index, title in
            .init(directoryRow: index, articleID: UInt32(index), level: 0, indexWithinLevel: UInt32(index), flags: 0,
                  relativeTartOffset: 0, titleSegments: [.init(selectorCode: nil, text: title)], positionLabel: nil, section: section)
        }
    }
    private func settle(_ controller: TopicSearchController) async throws {
        for _ in 0..<400 {
            if !controller.isLoading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Topic search did not settle")
    }
    @Test func bothLegacyFormatsPreserveOriginalResourceIdentityAndDiscloseActualFailures() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored text"]]); defer { fixture.remove() }
        let rows = try entries(["Creación", "Other"], fixture: fixture)
        let standalone = resource("one.LSF"), container = resource("two.lbxlls", format: .libronixLLS)
        let missing = resource("missing.lbxlls", format: .libronixLLS), oeb = resource("other.lbxobk", format: .libronixOEB)
        let controller = TopicSearchController { value in
            if value == missing { throw RebuildError.referenceNotFound }
            #expect(value != oeb)
            return rows
        }
        controller.search("creacion", resources: [standalone, container, missing, oeb]); try await settle(controller)
        #expect(controller.entries.map(\.resource.id) == [standalone.id, container.id])
        #expect(Set(controller.entries.map(\.id)).count == 2)
        #expect(controller.entries.allSatisfy { $0.entry == rows[0] })
        #expect(controller.failures.map(\.resource.id) == [missing.id])
        #expect(controller.status == .finished(matches: 2, unavailable: 1, limited: false))
    }
    @Test func boundedResultsAreDistinguishedFromAnExactlyCompleteResultSet() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored text"]]); defer { fixture.remove() }
        let three = try entries(["Topic A", "Topic B", "Topic C"], fixture: fixture)
        let two = Array(three.prefix(2)), source = resource("one.LSF")
        let limited = TopicSearchController(maximumResults: 2) { _ in three }
        limited.search("Topic", resources: [source]); try await settle(limited)
        #expect(limited.entries.count == 2 && limited.status == .finished(matches: 2, unavailable: 0, limited: true))
        let complete = TopicSearchController(maximumResults: 2) { _ in two }
        complete.search("Topic", resources: [source]); try await settle(complete)
        #expect(complete.status == .finished(matches: 2, unavailable: 0, limited: false))
        complete.search("Topic", resources: [source, resource("second.lbxlls", format: .libronixLLS)])
        try await settle(complete)
        #expect(complete.status == .finished(matches: 2, unavailable: 0, limited: true))
    }
    @Test func libraryChangesRejectLateResultsEvenWhenTheLoaderDoesNotCooperateWithCancellation() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored text"]]); defer { fixture.remove() }
        let rows = try entries(["Topic A"], fixture: fixture), gate = TopicDirectoryGate()
        let source = resource("one.lbxlls", format: .libronixLLS)
        let controller = TopicSearchController { value in await gate.load(value.id) }
        controller.search("Topic", resources: [source])
        try await gate.waitForStart(source.id)
        controller.libraryDidChange()
        await gate.finish(source.id, entries: rows)
        try await gate.waitForCompletion(source.id)
        #expect(controller.entries.isEmpty && controller.failures.isEmpty && !controller.isLoading)
        #expect(controller.status == .libraryChanged)
        controller.search(" ", resources: [source])
        #expect(controller.entries.isEmpty && controller.status == .idle && !controller.isLoading)
    }
    @Test func aLoaderCancellationDoesNotLeaveAnEndlessSpinner() async throws {
        let controller = TopicSearchController { _ in throw CancellationError() }
        controller.search("Topic", resources: [resource("one.LSF")]); try await settle(controller)
        #expect(controller.status == .canceled && controller.failures.isEmpty && controller.entries.isEmpty)
    }
    @Test(arguments: AppLanguage.allCases)
    func statusMessagesFollowTheCurrentInterfaceLanguage(language: AppLanguage) {
        let keys = ["Buscando…", "La biblioteca cambió. Vuelve a buscar.", "Búsqueda cancelada.", "{count} entradas",
            "Se muestran las primeras {count} entradas; quedan resultados o recursos por consultar.", "{count} recursos no disponibles"]
        for key in keys { #expect(AppStrings.catalog[key]?[language.rawValue] != nil) }
        let message = TopicSearchStatus.finished(matches: 2, unavailable: 1, limited: true).message(language: language, maximumResults: 2)
        #expect(!message.contains("{count}"))
        #expect(message.contains(AppStrings.format("{count} recursos no disponibles", language: language, values: ["count": "1"])))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"] != nil))
    func checkedDirectoriesInOriginalLSFAndLibronixContainersProduceOpenablePhysicalDestinations() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"]))
        var receipt: [[String: Any]] = []
        for name in ["RVR60.LSF", "rvr60.lbxlls", "RVR95.LSF", "LBLA95.lbxlls"] {
            let url = root.appendingPathComponent(name), index = url.deletingPathExtension().appendingPathExtension("LIX")
            let original = LibraryResource(location: url, indexLocation: FileManager.default.fileExists(atPath: index.path) ? index : nil,
                title: name, byteCount: 0, format: name.hasSuffix(".LSF") ? .legacyLSF : .libronixLLS,
                support: .metadataOnly, provenance: .fileName)
            let before = try LegacyGraphicsService.fileStamp(url)
            let directory = try await TopicDirectorySource.shared.directory(original)
            let entry = try #require(directory.first { $0.title?.isEmpty == false })
            let controller = TopicSearchController()
            controller.search(entry.displayTitle, resources: [original]); try await settle(controller)
            let result = try #require(controller.entries.first { $0.entry.directoryRow == entry.directoryRow })
            #expect(result.resource.id == original.id && result.resource.location == url)
            let opened = try await ReaderSession.read(result.resource, .init(ordinal: result.entry.sectionOrdinal))
            #expect(opened.destination.ordinal == entry.sectionOrdinal && !opened.text.isEmpty)
            #expect(try LegacyGraphicsService.fileStamp(url) == before)
            receipt.append(["file": name, "directoryEntries": directory.count, "originalResourceRetained": true,
                            "openedPhysicalArticle": entry.sectionOrdinal, "sourceUnchanged": true])
        }
        if let path = ProcessInfo.processInfo.environment["LIBRONX_TOPIC_RECEIPT"] {
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
}

private actor TopicDirectoryGate {
    private var pending: [String: CheckedContinuation<[LegacyArticleDirectoryEntry], Never>] = [:]
    private var completed: Set<String> = []
    func load(_ id: String) async -> [LegacyArticleDirectoryEntry] {
        let result = await withCheckedContinuation { pending[id] = $0 }
        completed.insert(id); return result
    }
    func finish(_ id: String, entries: [LegacyArticleDirectoryEntry]) { pending.removeValue(forKey: id)?.resume(returning: entries) }
    func waitForStart(_ id: String) async throws {
        for _ in 0..<400 { if pending[id] != nil { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Topic loader did not start")
    }
    func waitForCompletion(_ id: String) async throws {
        for _ in 0..<400 { if completed.contains(id) { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Topic loader did not return")
    }
}
