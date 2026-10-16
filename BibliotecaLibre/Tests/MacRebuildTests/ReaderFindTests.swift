import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

struct ReaderFindSourceTests {
    @Test func literalMatchingKeepsOriginalUnicodeRangesAndDoesNotInterpretQueryOperators() throws {
        let text = "😀 En el principio: A AND B; a\u{301}rbol; Árbol; gamma Gamma"
        let all = NSRange(location: 0, length: text.utf16.count)
        let literal = try #require(try ReaderFindSource.match(text, query: "A AND B", range: all, direction: .forward, options: .init()))
        #expect((text as NSString).substring(with: literal) == "A AND B")
        let emoji = try #require(try ReaderFindSource.match(text, query: "😀", range: all, direction: .forward, options: .init()))
        #expect(emoji == NSRange(location: 0, length: 2))
        var options = ReaderFindOptions(); options.diacriticSensitive = false
        let accent = try #require(try ReaderFindSource.match(text, query: "arbol", range: all, direction: .forward, options: options))
        #expect((text as NSString).substring(with: accent) == "a\u{301}rbol")
        let upper = try #require(try ReaderFindSource.match(text, query: "Gamma", range: all, direction: .backward, options: .init()))
        #expect((text as NSString).substring(with: upper) == "Gamma")
    }
    @Test func wholeWordOptionsRejectSubstringsButAcceptPhrasesWithWordBoundaries() throws {
        let text = "alphabet alpha ALPHA alpha beta"
        let all = NSRange(location: 0, length: text.utf16.count)
        var options = ReaderFindOptions(); options.wholeWords = true
        let word = try #require(try ReaderFindSource.match(text, query: "alpha", range: all, direction: .forward, options: options))
        #expect(word.location == 9)
        options.caseSensitive = true
        let uppercase = try #require(try ReaderFindSource.match(text, query: "ALPHA", range: all, direction: .forward, options: options))
        #expect(uppercase.location == 15)
        let phrase = try #require(try ReaderFindSource.match(text, query: "alpha beta", range: all, direction: .forward, options: options))
        #expect((text as NSString).substring(with: phrase) == "alpha beta")
        #expect(try ReaderFindSource.match(text, query: "", range: all, direction: .forward, options: options) == nil)
        #expect(try ReaderFindSource.match(text, query: "alpha", range: NSRange(location: -1, length: 9), direction: .forward, options: options) == nil)
    }
    @Test func forwardBackwardAndWrappingTraverseTheCompleteResource() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Cover", "Gamma then gamma", "Last Gamma"]]); defer { fixture.remove() }
        let resource = fixture.resources[0]
        let before = try Data(contentsOf: resource.location)
        let first = try #require(try await ReaderFindSource.find(resource, .init(query: "Gamma", ordinal: 0, position: 0)))
        #expect(first.ordinal == 1 && first.range.location == 0 && !first.wrapped)
        let second = try #require(try await ReaderFindSource.find(resource, .init(query: "Gamma", ordinal: 1, position: NSMaxRange(first.range))))
        #expect(second.ordinal == 1 && second.range.location == 11)
        let prior = try #require(try await ReaderFindSource.find(resource, .init(query: "Gamma", ordinal: 1, position: second.range.location, direction: .backward)))
        #expect(prior.ordinal == 1 && prior.range == first.range)
        let wrapped = try #require(try await ReaderFindSource.find(resource, .init(query: "Gamma", ordinal: 2, position: 10)))
        #expect(wrapped.ordinal == 1 && wrapped.wrapped)
        var options = ReaderFindOptions(); options.wraps = false
        #expect(try await ReaderFindSource.find(resource, .init(query: "Gamma", ordinal: 2, position: 10, options: options)) == nil)
        let backward = try #require(try await ReaderFindSource.find(resource, .init(query: "Gamma", ordinal: 0, position: 0, direction: .backward)))
        #expect(backward.ordinal == 2 && backward.wrapped)
        #expect(try Data(contentsOf: resource.location) == before)
    }
    @Test func corruptArticlesAreAnExplicitFailureRatherThanASilentNoMatch() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Cover", nil, "Gamma"]]); defer { fixture.remove() }
        do {
            _ = try await ReaderFindSource.find(fixture.resources[0], .init(query: "Gamma", ordinal: 0, position: 0))
            Issue.record("Skipped an unreadable article without reporting it")
        } catch { #expect(error is LegacyContentError) }
    }
}

@MainActor struct ReaderFindStateTests {
    private func settle(_ reader: ReaderSession) async throws {
        for _ in 0..<1000 {
            if !reader.isLoading && reader.findStatus != .searching { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Reader did not settle")
    }
    @Test func incrementalFindNoMatchAndReopeningRetainTheCommittedWordAndHistory() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Cover", "Gamma then gamma"]]); defer { fixture.remove() }
        let reader = ReaderSession(resource: fixture.resources[0])
        reader.load(.init(ordinal: 0)); try await settle(reader)
        reader.showFind(); reader.updateFindQuery("Gamma"); try await settle(reader)
        #expect(reader.page?.destination.ordinal == 1 && reader.selectedText == "Gamma")
        reader.find(.forward); try await settle(reader)
        #expect(reader.selectedText == "gamma" && reader.selectedRange.location == 11)
        reader.find(.backward); try await settle(reader)
        #expect(reader.selectedText == "Gamma" && reader.selectedRange.location == 0)
        let request = reader.selectionRequest, history = reader.history
        reader.updateFindQuery("NoMatchAuthored"); try await settle(reader)
        #expect(reader.findStatus == .notFound && reader.selectedText == "Gamma")
        #expect(reader.selectionRequest == request && reader.history == history)
        reader.hideFind(); reader.showFind()
        #expect(reader.findQuery == "Gamma" && reader.findStatus == .notFound)
        reader.find(.forward); try await settle(reader)
        #expect(reader.selectedText == "gamma" && reader.findStatus == .found(wrapped: false))
    }
    @Test func supersededCancelledAndClosedSearchesCannotCommitEvenIfTheirLoaderIgnoresCancellation() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Cover", "Gamma"]]); defer { fixture.remove() }
        let slow: ReaderSession.FindLoader = { _, _ in
            try? await Task.sleep(for: .milliseconds(30))
            return .init(ordinal: 1, range: NSRange(location: 0, length: 5), fingerprint: LibrarySearchService.textFingerprint("Gamma"), wrapped: false)
        }
        let reader = ReaderSession(resource: fixture.resources[0], findLoader: slow)
        reader.load(.init(ordinal: 0)); try await settle(reader)
        reader.findQuery = "Gamma"; reader.find(.forward); reader.cancel()
        try await Task.sleep(for: .milliseconds(80))
        #expect(reader.page?.destination.ordinal == 0 && reader.history.count == 1)
        reader.find(.forward); reader.load(.init(ordinal: 0))
        try await Task.sleep(for: .milliseconds(80))
        #expect(reader.page?.destination.ordinal == 0 && reader.selectedText.isEmpty)
    }
    @Test func fingerprintMismatchCannotApplyFindSelectionToChangedText() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Cover", "Changed"]]); defer { fixture.remove() }
        let mismatch: ReaderSession.FindLoader = { _, _ in
            .init(ordinal: 1, range: NSRange(location: 0, length: 5), fingerprint: LibrarySearchService.textFingerprint("Gamma"), wrapped: false)
        }
        let reader = ReaderSession(resource: fixture.resources[0], findLoader: mismatch)
        reader.load(.init(ordinal: 0)); try await settle(reader)
        reader.findQuery = "Gamma"; reader.find(.forward); try await settle(reader)
        if case .failed = reader.findStatus {} else { Issue.record("Expected a source-change failure") }
        #expect(reader.page?.destination.ordinal == 0 && reader.history.count == 1)
    }
}

struct LocalFindCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_FIND_CORPUS"] != nil))
    func originalGuiagrkGammaSequenceAgreesWithTheSealedReferenceCase() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_FIND_CORPUS"]))
        let url = directory.appendingPathComponent("GUIAGRK.LSF")
        let before = try LegacyGraphicsService.fileStamp(url)
        let resource = LibraryResource(location: url, title: "Guía para el estudio del Griego del Nuevo Testamento", byteCount: Int64(before.size),
                                       format: .legacyLSF, support: .metadataOnly, provenance: .legacyPublicMetadata)
        let first = try #require(try await ReaderFindSource.find(resource, .init(query: "Gamma", ordinal: 0, position: 0)))
        #expect(first.ordinal == 140)
        let content = try LegacyContentReader.readSection(lsfURL: url, ordinal: first.ordinal)
        #expect((content.plainText as NSString).substring(with: first.range) == "Gamma")
        let next = try #require(try await ReaderFindSource.find(resource, .init(query: "Gamma", ordinal: first.ordinal, position: NSMaxRange(first.range))))
        #expect(next.ordinal == 140 && (content.plainText as NSString).substring(with: next.range) == "gamma")
        let previous = try #require(try await ReaderFindSource.find(resource, .init(query: "Gamma", ordinal: next.ordinal, position: next.range.location, direction: .backward)))
        #expect(previous.ordinal == first.ordinal && previous.range == first.range)
        #expect(try await ReaderFindSource.find(resource, .init(query: "LibronXzzNoMatch20261012", ordinal: first.ordinal, position: first.range.location)) == nil)
        #expect(try LegacyGraphicsService.fileStamp(url) == before)
        print("GUIAGRK Find verified: table Gamma=\(first.range), prose gamma=\(next.range), ordinal=\(first.ordinal)")
    }
}
