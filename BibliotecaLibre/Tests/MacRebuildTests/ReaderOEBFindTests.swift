import AppKit
import WebKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct ReaderOEBFindTests {
    private func settle(_ reader: ReaderSession, candidate: Int? = nil) async throws {
        let until = Date().addingTimeInterval(10)
        while Date() < until {
            if let candidate, reader.page?.destination.ordinal == candidate { return }
            if !reader.isLoading && reader.findStatus != .searching { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("OEB Find did not settle: \(reader.findStatus)")
    }
    @Test func nativeProjectionPartitionsSharedArticlesAndExcludesHiddenText() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(); defer { fixture.remove() }
        let book = try await LibronixOEBService.shared.prepare(fixture.resource.location)
        let page = try await ReaderOEBTextSource.shared.read(book: book, path: "Chapter.html", viewport: .init())
        let first = try #require(page.articleRanges[1]), second = try #require(page.articleRanges[2])
        #expect(first.location == 0 && NSMaxRange(first) == second.location && NSMaxRange(second) == page.text.utf16.count)
        #expect(!page.text.contains("InvisibleNeedle"))
        #expect((page.text as NSString).substring(with: second) == "SecondGamma second")
        #expect(page.text.contains("a\u{301}rbol 😀"))
        let cached = try await ReaderOEBTextSource.shared.read(book: book, path: "Chapter.html", viewport: .init())
        #expect(cached.text == page.text && cached.articleRanges == page.articleRanges)
    }
    @Test func forwardBackwardWrapAndSharedPageArticleOrderDoNotDuplicateHits() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(); defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.resource.location)
        var ordinal = 0, position = 0, sequence: [Int] = [], hits: [ReaderFindMatch] = []
        for _ in 0..<6 {
            let match = try #require(try await ReaderFindSource.find(fixture.resource, .init(query: "Gamma", ordinal: ordinal, position: position)))
            sequence.append(match.ordinal); hits.append(match); ordinal = match.ordinal; position = NSMaxRange(match.range)
        }
        #expect(sequence == [1,1,1,2,3,1])
        #expect(!hits[4].wrapped && hits[5].wrapped)
        let prior = try #require(try await ReaderFindSource.find(fixture.resource, .init(query: "Gamma", ordinal: 2, position: hits[3].range.location, direction: .backward)))
        #expect(prior.ordinal == 1 && prior.range == hits[2].range)
        var options = ReaderFindOptions(); options.wraps = false
        #expect(try await ReaderFindSource.find(fixture.resource, .init(query: "Gamma", ordinal: 3, position: NSMaxRange(hits[4].range), options: options)) == nil)
        let back = try #require(try await ReaderFindSource.find(fixture.resource, .init(query: "Gamma", ordinal: 0, position: 0, direction: .backward)))
        #expect(back.ordinal == 3 && back.wrapped)
        #expect(try await ReaderFindSource.find(fixture.resource, .init(query: "Delta", ordinal: 2, position: 0, options: options)) == nil)
        #expect(try Data(contentsOf: fixture.resource.location) == original)
    }
    @Test func optionsKeepCombiningMarksAndLiteralTextInSourceCoordinates() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(); defer { fixture.remove() }
        var options = ReaderFindOptions(); options.caseSensitive = true
        let lower = try #require(try await ReaderFindSource.find(fixture.resource, .init(query: "gamma", ordinal: 0, position: 0, options: options)))
        #expect((lower.oebProjection!.text as NSString).substring(with: lower.range) == "gamma")
        options.diacriticSensitive = false; options.wholeWords = true
        let combining = try #require(try await ReaderFindSource.find(fixture.resource, .init(query: "arbol", ordinal: 0, position: 0, options: options)))
        #expect((combining.oebProjection!.text as NSString).substring(with: combining.range) == "a\u{301}rbol")
        options.wholeWords = true
        #expect(try await ReaderFindSource.find(fixture.resource, .init(query: "Gam", ordinal: 0, position: 0, options: options)) == nil)
        #expect(try await ReaderFindSource.find(fixture.resource, .init(query: "InvisibleNeedle", ordinal: 0, position: 0)) == nil)
        #expect(try await ReaderFindSource.find(fixture.resource, .init(query: "Gamma AND Delta", ordinal: 0, position: 0)) == nil)
    }
    @Test func cancelledProjectionAndMissingStylesAreExplicitFailures() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(missingStyle: true); defer { fixture.remove() }
        do {
            _ = try await ReaderFindSource.find(fixture.resource, .init(query: "Gamma", ordinal: 0, position: 0))
            Issue.record("Search ignored a missing author stylesheet")
        } catch { #expect(error is PersonalStateError) }
        let owned = try AuthoredOEBFixture(); defer { owned.remove() }
        let task = Task { try await ReaderFindSource.find(owned.resource, .init(query: "Gamma", ordinal: 0, position: 0)) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled OEB search returned a hit") }
        catch { #expect(error is CancellationError) }
    }
    @Test func matchingDOMCommitsNavigationAndMismatchingDOMOrCancellationRestoresCommittedState() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(); defer { fixture.remove() }
        let workspace = StudyWorkspace(), reader = workspace.open(fixture.resource, startReading: false)
        reader.load(.init(ordinal: 0)); try await settle(reader)
        let cover = try #require(reader.page?.oeb)
        let text = try await ReaderOEBTextSource.shared.read(book: cover.book, path: "Cover.html", viewport: .init()).text
        try reader.acceptOEBProjection(text, at: cover.url)
        reader.findQuery = "Gamma"; reader.find(.forward); try await settle(reader, candidate: 1)
        #expect(reader.history.map(\.ordinal) == [0] && reader.selectedRange.length == 0)
        #expect(workspace.archive().panes[0].destination?.ordinal == 0)
        let copy = workspace.duplicate(reader)
        #expect(copy.page?.destination.ordinal == 0)
        workspace.close(copy)
        reader.cancelFind()
        #expect(reader.page?.destination.ordinal == 0 && reader.history.map(\.ordinal) == [0])
        reader.find(.forward); try await settle(reader, candidate: 1)
        let candidateURL = try #require(reader.page?.oeb?.url)
        #expect(throws: LibronixBookError.sourceChanged) { try reader.acceptOEBProjection("Changed", at: candidateURL) }
        #expect(reader.page?.destination.ordinal == 0 && reader.history.map(\.ordinal) == [0])
        reader.find(.forward); try await settle(reader, candidate: 1)
        let candidate = try #require(reader.page?.oeb)
        let projection = try await ReaderOEBTextSource.shared.read(book: candidate.book, path: "Chapter.html", viewport: .init())
        try reader.acceptOEBProjection(projection.text, at: candidate.url)
        #expect(reader.page?.destination.ordinal == 1 && reader.selectedText == "Gamma" && reader.findStatus == .found(wrapped: false))
        #expect(reader.history.map(\.ordinal) == [0,1])
        let range = reader.selectedRange, history = reader.history
        reader.findQuery = "NoMatchOwned"; reader.find(.forward); try await settle(reader)
        #expect(reader.findStatus == .notFound && reader.selectedRange == range && reader.history == history)
        reader.cancel()
    }
    @Test func sourceReplacementBetweenMatchAndDOMCommitRejectsTheRange() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(); defer { fixture.remove() }
        let reader = ReaderSession(resource: fixture.resource)
        reader.load(.init(ordinal: 0)); try await settle(reader)
        let first = try #require(reader.page?.oeb)
        let cover = try await ReaderOEBTextSource.shared.read(book: first.book, path: "Cover.html", viewport: .init())
        try reader.acceptOEBProjection(cover.text, at: first.url)
        reader.findQuery = "Gamma"; reader.find(.forward); try await settle(reader, candidate: 1)
        let page = try #require(reader.page?.oeb)
        let target = try #require(page.book.directory.articles.first { $0.ordinal == 1 })
        let projection = try await ReaderOEBTextSource.shared.read(book: page.book, path: target.path, viewport: .init())
        try Data([0]).write(to: fixture.resource.location)
        #expect(throws: LibronixBookError.sourceChanged) { try reader.acceptOEBProjection(projection.text, at: page.url) }
        #expect(reader.page?.destination.ordinal == 0 && reader.history.map(\.ordinal) == [0])
        reader.cancel()
    }
}
