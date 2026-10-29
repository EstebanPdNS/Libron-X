import Foundation

/// Immutable projections supplied by the owning personal-document editor.
/// Fields stay separate: a title ending in a book name cannot borrow a verse
/// number from the next field to manufacture a citation.
public struct BibleReferencePersonalField: Codable, Sendable {
    public enum Kind: String, Sendable, Codable { case documentTitle, noteTitle, noteBody, noteAnchor, verseEntry, sermonPassages }
    public let entryID: UUID?
    public let kind: Kind
    public let text: String
    public let links: [BibleReferenceSourceLink]
    public init(entryID: UUID? = nil, kind: Kind, text: String, links: [BibleReferenceSourceLink] = []) {
        self.entryID = entryID; self.kind = kind; self.text = text; self.links = links
    }
    public func projectionFingerprint() throws -> String {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        // Bind both the visible text and nonvisible explicit link destinations.
        return LibrarySearchService.textFingerprint(String(decoding:try encoder.encode(self),as:UTF8.self))
    }
    var id: String { kind.rawValue + ":" + (entryID?.uuidString ?? "document") }
}
public struct BibleReferencePersonalSource: Sendable {
    public let documentID: UUID
    public let title: String
    public let fields: [BibleReferencePersonalField]
    public let warnings: [String]
    public let projectionComplete: Bool
    public init(documentID: UUID, title: String, fields: [BibleReferencePersonalField], warnings: [String] = [], projectionComplete: Bool = true) {
        self.documentID = documentID; self.title = title; self.fields = fields; self.warnings = warnings; self.projectionComplete = projectionComplete
    }
}
public struct BibleReferencePersonalDestination: Sendable {
    public let documentID: UUID
    public let entryID: UUID?
    public let field: BibleReferencePersonalField.Kind
    public let textSHA256: String
    public let projectionSHA256: String
    public let range: SearchTextRange
    public init(documentID: UUID, entryID: UUID?, field: BibleReferencePersonalField.Kind,
                textSHA256: String, projectionSHA256: String, range: SearchTextRange) {
        self.documentID = documentID; self.entryID = entryID; self.field = field
        self.textSHA256 = textSHA256; self.projectionSHA256 = projectionSHA256; self.range = range
    }
}
public struct BibleReferenceSearchResult: Identifiable, Sendable {
    public let mention: BibleReferenceMention
    public let sourceTitle: String
    public let snippet: LibrarySearchSnippet
    public let resourceDestination: LibrarySearchResult?
    public let personalDestination: BibleReferencePersonalDestination?
    public var id: String {
        let owner = resourceDestination.map { "resource:" + $0.id } ?? personalDestination.map {
            "document:" + $0.documentID.uuidString + ":" + ($0.entryID?.uuidString ?? "title") + ":" + $0.field.rawValue
        } ?? "unresolved"
        return owner + ":" + String(mention.range.location) + ":" + String(mention.range.length)
    }
}
public struct BibleReferencePersonalReport: Sendable {
    public let documentID: UUID
    public let title: String
    public var fieldsTotal: Int
    public var fieldsExamined = 0
    public var fieldsFailed = 0
    public var warnings: [String]
    public var errors: [String] = []
    public var complete = false
}
public struct BibleReferenceSearchReport: Sendable {
    public let query: String
    public let results: [BibleReferenceSearchResult]
    public let resources: [LibrarySearchResourceReport]
    public let documents: [BibleReferencePersonalReport]
    public let counters: LibrarySearchCounters
    public let personalFieldsExamined: Int
    public let limitReason: LibrarySearchLimit?
    public let elapsedSeconds: Double
    /// Every requested source field/article was examined under the documented
    /// explicit-reference grammar. It is not a versification-equivalence claim.
    public let coverageComplete: Bool
}

public struct BibleReferenceSearchProgress: Sendable {
    public let counters: LibrarySearchCounters
    public let personalFieldsExamined: Int
    public let currentSourceTitle: String?
    public let elapsedSeconds: Double
}

public actor BibleReferenceSearchService {
    private let provider: any LibrarySearchContentProvider
    public init(provider: any LibrarySearchContentProvider) { self.provider = provider }
    public init(contentService: LegacyContentService = LegacyContentService()) { self.provider = LibrarySearchReader(contentService:contentService) }
    public func search(resources: [LibraryResource], documents: [BibleReferencePersonalSource] = [], query: BibleReferenceQuery,
                       budget: LibrarySearchBudget = .init(),
                       onProgress: (@Sendable (BibleReferenceSearchProgress) async -> Void)? = nil) async throws -> BibleReferenceSearchReport {
        guard budget.maximumDurationSeconds.isFinite, (0...3600).contains(budget.maximumDurationSeconds), budget.maximumDurationSeconds > 0,
              (1...500_000).contains(budget.maximumArticles), (1...10_000).contains(budget.maximumResults),
              (1...1_000_000).contains(budget.maximumOccurrences), (1...4096).contains(budget.snippetUTF16),
              (1...10_000).contains(budget.progressBatchSize) else { throw LibrarySearchError.invalidBudget }
        try Task.checkCancellation()
        guard Set(resources.map(\.id)).count == resources.count else { throw LibrarySearchError.duplicateResourceID("reference search") }
        guard documents.count <= 100, Set(documents.map(\.documentID)).count == documents.count,
              documents.allSatisfy({ $0.fields.count <= 300_001 && Set($0.fields.map(\.id)).count == $0.fields.count && $0.fields.allSatisfy { ($0.kind == .documentTitle || $0.kind == .sermonPassages) == ($0.entryID == nil) } }) else {
            throw PersonalStateError.invalid("El ámbito de documentos contiene campos duplicados o supera sus límites.")
        }
        let operand = SearchTextOperand(text:query.original,sourceRange:.init(location:0,length:query.original.utf16.count))
        let clock = ContinuousClock(), started = clock.now
        func elapsed() -> Double {
            let c = started.duration(to:clock.now).components
            return Double(c.seconds)+Double(c.attoseconds)/1e18
        }
        var counters = LibrarySearchCounters(); counters.resourcesTotal = resources.count
        counters.resourcesWithUnknownArticleTotal = resources.count
        var personalExamined = 0, results: [BibleReferenceSearchResult] = []
        var reports = resources.map(LibrarySearchResourceReport.init)
        var personal = documents.map { BibleReferencePersonalReport(documentID:$0.documentID,title:$0.title,fieldsTotal:$0.fields.count,warnings:$0.warnings) }
        var prepared: [(LibraryResource,LibrarySearchPreparedResource)] = []
        var limit: LibrarySearchLimit?
        func reached() -> LibrarySearchLimit? {
            if elapsed() >= budget.maximumDurationSeconds { return .duration }
            if personalExamined+counters.articlesExamined >= budget.maximumArticles { return .articles }
            if results.count >= budget.maximumResults { return .results }
            if results.count >= budget.maximumOccurrences { return .occurrences }
            return nil
        }
        func progress(_ title: String?) -> BibleReferenceSearchProgress {
            .init(counters:counters,personalFieldsExamined:personalExamined,currentSourceTitle:title,elapsedSeconds:elapsed())
        }
        func critical(_ error: any Error) throws {
            if error is CancellationError { throw CancellationError() }
            if let changed = error as? LegacyIndicesError, changed == .sourceChanged { throw changed }
        }
        // Personal fields are inexpensive snapshots and cannot be starved by
        // a large library. Their independent totals remain explicit.
        personalLoop: for index in documents.indices {
            let document = documents[index]
            for field in document.fields {
                try Task.checkCancellation()
                if let value = reached() { limit = value; break personalLoop }
                personalExamined += 1; personal[index].fieldsExamined += 1
                do {
                    let mentions = try BibleReferenceMentions.extract(field.text,links:field.links).filter(query.matches)
                    if elapsed() >= budget.maximumDurationSeconds { limit = .duration; break personalLoop }
                    let hash = mentions.isEmpty ? "" : LibrarySearchService.textFingerprint(field.text)
                    let projectionHash = mentions.isEmpty ? "" : try field.projectionFingerprint()
                    for mention in mentions {
                        if let value = reachedWithoutArticles() { limit = value; break personalLoop }
                        let hits = [TextSearchHit(range:mention.range,operands:[operand])]
                        let snippet = LibrarySearchService.snippet(field.text,hits:hits,maximumUTF16:budget.snippetUTF16)
                        results.append(.init(mention:mention,sourceTitle:document.title,snippet:snippet,resourceDestination:nil,
                            personalDestination:.init(documentID:document.documentID,entryID:field.entryID,field:field.kind,textSHA256:hash,projectionSHA256:projectionHash,range:mention.range)))
                    }
                } catch { try critical(error); personal[index].fieldsFailed += 1;personal[index].errors.append(error.localizedDescription) }
                if personalExamined.isMultiple(of:budget.progressBatchSize) { await onProgress?(progress(document.title)) }
            }
            personal[index].complete = document.projectionComplete && personal[index].fieldsFailed == 0 && personal[index].fieldsExamined == document.fields.count
        }
        // A processed final article is still allowed to return its own matches.
        func reachedWithoutArticles() -> LibrarySearchLimit? {
            if elapsed() >= budget.maximumDurationSeconds { return .duration }
            if results.count >= budget.maximumResults { return .results }
            if results.count >= budget.maximumOccurrences { return .occurrences }
            return nil
        }
        await onProgress?(progress(nil))
        for index in resources.indices {
            try Task.checkCancellation()
            if !(await provider.supports(resources[index])) || resources[index].support == .invalidFile {
                reports[index].status = .incompatible;reports[index].warnings = ["Contenido incompatible con la búsqueda de referencias."]
                counters.resourcesIncompatible += 1;counters.resourcesExamined += 1
            }
        }
        resourceLoop: for index in resources.indices {
            try Task.checkCancellation()
            if limit != nil { break }
            if reports[index].status == .incompatible { continue }
            if let value = reached() { limit = value; break }
            let resource = resources[index];counters.resourcesExamined += 1
            let source: LibrarySearchPreparedResource
            do {
                source = try await provider.prepare(resource)
                try source.validateDirectory()
                try await provider.verifyUnchanged(resource,prepared:source)
            } catch {
                try critical(error);reports[index].status = .failed;counters.resourcesFailed += 1
                reports[index].errors.append(.init(sectionOrdinal:nil,code:"reference-source",message:error.localizedDescription));continue
            }
            prepared.append((resource,source));counters.resourcesPrepared += 1;counters.resourcesWithUnknownArticleTotal -= 1
            counters.articlesTotalKnown += source.articleCount;reports[index].totalArticles = source.articleCount
            reports[index].status = .partial;reports[index].warnings = source.warnings
            for article in source.orderedArticles() {
                try Task.checkCancellation()
                if let value = reached() { limit = value;break resourceLoop }
                counters.articlesExamined += 1;reports[index].articlesExamined += 1
                do {
                    try await provider.verifyUnchanged(resource,prepared:source)
                    let content = try await provider.read(resource,article:article,prepared:source)
                    try await provider.verifyUnchanged(resource,prepared:source)
                    let mentions = try BibleReferenceMentions.extract(content.text,within:content.searchRange,links:content.referenceLinks ?? []).filter(query.matches)
                    counters.articlesDecoded += 1;reports[index].articlesDecoded += 1
                    if elapsed() >= budget.maximumDurationSeconds { limit = .duration;break resourceLoop }
                    if !mentions.isEmpty { counters.matchingArticles += 1;reports[index].matchingArticles += 1 }
                    counters.occurrencesObserved += mentions.count;reports[index].occurrencesObserved += mentions.count
                    let hash = mentions.isEmpty ? "" : LibrarySearchService.textFingerprint(content.text)
                    for mention in mentions {
                        if let value = reachedWithoutArticles() { limit = value;break resourceLoop }
                        let hits = [TextSearchHit(range:mention.range,operands:[operand])]
                        let snippet = LibrarySearchService.snippet(content.text,hits:hits,maximumUTF16:budget.snippetUTF16,within:content.searchRange)
                        let destination = LibrarySearchResult(resourceID:resource.id,resourceTitle:resource.title,sectionOrdinal:article.sectionOrdinal,
                            articleTitle:article.title,hitCount:1,hits:hits,snippet:snippet,decodedTextSHA256:hash,sourceStamps:source.sourceStamps,
                            presentationWarnings:content.warnings,bibleReference:nil,verseRange:nil)
                        results.append(.init(mention:mention,sourceTitle:resource.title,snippet:snippet,resourceDestination:destination,personalDestination:nil))
                        counters.resultsReturned += 1;counters.occurrencesReturned += 1;reports[index].resultsReturned += 1
                    }
                } catch {
                    try critical(error);counters.articlesFailed += 1;reports[index].articlesFailed += 1
                    reports[index].errors.append(.init(sectionOrdinal:article.sectionOrdinal,code:"reference-article",message:error.localizedDescription))
                }
                if counters.articlesExamined.isMultiple(of:budget.progressBatchSize) { await onProgress?(progress(resource.title)) }
            }
            if reports[index].articlesExamined == source.articleCount, reports[index].articlesFailed == 0 {
                reports[index].status = .complete;counters.resourcesCompleted += 1
            }
            await onProgress?(progress(resource.title))
        }
        await onProgress?(progress(nil))
        for (resource,source) in prepared { try await provider.verifyUnchanged(resource,prepared:source) }
        try Task.checkCancellation()
        return .init(query:query.original,results:results,resources:reports,documents:personal,counters:counters,personalFieldsExamined:personalExamined,
                     limitReason:limit,elapsedSeconds:elapsed(),coverageComplete:limit == nil && counters.resourcesCompleted == resources.count && personal.allSatisfy(\.complete))
    }
}
