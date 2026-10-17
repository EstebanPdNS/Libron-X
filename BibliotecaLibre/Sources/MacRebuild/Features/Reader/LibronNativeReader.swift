import AppKit
import CryptoKit
import Foundation
import LibronixCore

struct LibronNativeHeader: Codable {
    var schemaVersion = 1
    var resourceID: String
    var sourceSHA256: String
    var sectionCount: Int
    var profile: String
    var entries: [ReaderEntry]
    var chapters: [BibleChapterBook]
}
struct LibronNativeSection: Codable {
    var text: String
    var content: LegacySectionContent?
    var typographyKey: String?
    var graphics: [LegacyGraphicAsset]
    var inlineLinks: [LegacyInlineLink]
    var interlinearLines: [LibronixInterlinearLineDefinition]
    var warning: String?
    var referenceEnds: [Int:Int]? = nil
}
struct LibronNativeHTMLIndex: Codable {
    var directory: LibronixOEBDirectory
    var members: [String:String]
}
struct LibronNativeHTML: Codable {
    var directory: LibronixOEBDirectory
    var members: [String: Data]
}
struct LibronNormalizationReceipt: Codable {
    var schemaVersion = 1
    var converterVersion: Int? = 2
    var navigationVersion: Int? = 2
    var resourceID: String
    var sourceSHA256: String
    var state: String
    var profile: String
    var sections: Int
    var checkedSections: Int
    var warnings: [String]
}

actor LibronNativeReader {
    static let shared = LibronNativeReader()
    private var headers: [URL: LibronNativeHeader] = [:]
    private var htmlBooks: [URL: LibronixOEBBook] = [:]
    nonisolated static func location(_ resource: LibraryResource) -> URL? {
        guard let package = resource.packageLocation else { return nil }
        let path = package.appendingPathComponent("normalized/reader.sqlite")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }
    func header(_ resource: LibraryResource) throws -> LibronNativeHeader? {
        guard let url = Self.location(resource) else { return nil }
        if let saved = headers[url] { return saved }
        let db = try LibronNativeDatabase(url)
        guard let data = try db.get("header") else { throw LibronError.invalid("Missing normalized header") }
        let result = try JSONDecoder().decode(LibronNativeHeader.self, from: data)
        let manifestHash = try resource.packageLocation.map { try LibronPackage.read($0).0.payload.sha256 }
        guard result.schemaVersion == 1, result.resourceID == resource.id, result.sourceSHA256 == manifestHash, result.sectionCount > 0 else { throw LibronError.invalid("Invalid normalized resource identity") }
        if headers.count > 64 { headers.removeAll() }
        headers[url] = result
        return result
    }
    func read(_ resource: LibraryResource, _ requested: ReaderDestination) throws -> ReaderPage {
        guard let url = Self.location(resource), let header = try header(resource) else { throw RebuildError.unsupportedFormat }
        let db = try LibronNativeDatabase(url)
        if header.profile == "html" {
            let book: LibronixOEBBook
            if let saved = htmlBooks[url] { book = saved }
            else {
                let html: LibronNativeHTML
                if let data = try db.get("html-index") {
                    let index = try JSONDecoder().decode(LibronNativeHTMLIndex.self,from:data)
                    var members: [String:Data] = [:]
                    for (path,key) in index.members {
                        if key.isEmpty { members[path] = Data(); continue }
                        guard let data = try db.get(key) else { throw LibronError.invalid("Missing normalized HTML member") }
                        members[path] = data
                    }
                    html = .init(directory:index.directory,members:members)
                } else {
                    guard let data = try db.get("html") else { throw LibronError.invalid("Missing normalized HTML") }
                    html = try JSONDecoder().decode(LibronNativeHTML.self,from:data)
                }
                book = try LibronixOEBBook(source:url,directory:html.directory,members:html.members)
                if htmlBooks.count >= 4 { htmlBooks.removeAll() };htmlBooks[url] = book
            }
            var ordinal = requested.ordinal
            var fragment = requested.reference
            if resource.format != .epub, let reference = requested.reference,
               let article = book.directory.articles.first(where: { $0.fragment == reference || $0.title.localizedCaseInsensitiveCompare(reference) == .orderedSame || $0.path.lowercased() == reference.lowercased() }) {
                ordinal = article.ordinal; fragment = article.fragment
            }
            guard book.directory.articles.indices.contains(ordinal) else { throw RebuildError.referenceNotFound }
            let article = book.directory.articles[ordinal]
            if resource.format != .epub { fragment = fragment ?? article.fragment }
            if let fragment, !fragment.isEmpty, fragment != article.fragment {
                guard let path = book.path(for:book.url(path:article.path)), let data = book.members[path],
                      let html = String(data:data,encoding:.utf8) else { throw RebuildError.referenceNotFound }
                let escaped = NSRegularExpression.escapedPattern(for:fragment)
                let pattern = "(?i:\\b(?:id|name)\\s*=\\s*)(?:\""+escaped+"\"|'"+escaped+"'|"+escaped+"(?=[\\s>]))"
                guard html.range(of:pattern,options:[.regularExpression]) != nil else { throw RebuildError.referenceNotFound }
            }
            return .init(destination:.init(ordinal:ordinal,reference:fragment),text:"",sectionCount:header.sectionCount,entries:header.entries,
                oeb:.init(book:book,url:book.url(path:article.path,fragment:fragment)))
        }
        var ordinal = requested.ordinal
        if requested.prefersContentsStart == true { ordinal = header.entries.first?.ordinal ?? ordinal }
        let match = try requested.reference.map { reference in
            guard let result = try db.resolve(reference) else { throw RebuildError.referenceNotFound };return result
        }
        if let match { ordinal = match.ordinal }
        func section(_ ordinal: Int) throws -> LibronNativeSection {
            guard (0..<header.sectionCount).contains(ordinal), let data = try db.get("section/\(ordinal)") else { throw RebuildError.referenceNotFound }
            return try JSONDecoder().decode(LibronNativeSection.self,from:data)
        }
        let stored = try section(ordinal)
        let typography: LegacyTypography?
        if let key = stored.typographyKey, let data = try db.get(key) { typography = try JSONDecoder().decode(LegacyTypography.self,from:data) } else { typography = nil }
        var selection: NSRange?
        func verseEnd(_ value: LibronNativeSection, offset: Int, reference: String) -> Int {
            if let end = value.referenceEnds?[offset], end > offset, end <= value.text.utf16.count { return end }
            let key = LegacyPassageQuery.sourceReference(reference)?.normalizedKey
            return value.content?.anchors.first {
                $0.reference != nil && $0.characterOffset > offset && $0.reference.flatMap(LegacyPassageQuery.sourceReference)?.normalizedKey != key
            }?.characterOffset ?? value.text.utf16.count
        }
        if let match { selection = .init(location:match.offset,length:max(0,verseEnd(stored,offset:match.offset,reference:match.reference)-match.offset)) }
        var parts: [ReaderPassagePart] = []
        if let end = requested.endReference, let current = match {
            let first: (ordinal: Int, offset: Int, reference: String)
            if let start = requested.passageStartReference {
                guard let resolved = try db.resolve(start) else { throw RebuildError.referenceNotFound }; first = resolved
            } else { first = current }
            guard let last = try db.resolve(end), last.ordinal >= first.ordinal, last.ordinal - first.ordinal < 256,
                  (first.ordinal...last.ordinal).contains(ordinal) else { throw RebuildError.invalidPassagePart }
            for index in first.ordinal...last.ordinal {
                let value = index == ordinal ? stored : try section(index)
                guard let content = value.content else { throw RebuildError.invalidPassagePart }
                let lower = index == first.ordinal ? first.offset : 0
                let upper = index == last.ordinal ? verseEnd(value,offset:last.offset,reference:last.reference) : value.text.utf16.count
                guard upper >= lower else { throw RebuildError.invalidPassagePart }
                let range = NSRange(location:lower,length:upper-lower)
                parts.append(.init(content:content,selection:range,reference:index == first.ordinal ? first.reference : value.content?.anchors.compactMap { $0.reference.flatMap(LegacyPassageQuery.sourceReference)?.displayReference }.first ?? last.reference,graphics:value.graphics))
                if index == ordinal { selection = range }
            }
        }
        return .init(destination:.init(ordinal:ordinal,reference:parts.first(where: { $0.ordinal == ordinal })?.reference ?? match?.reference,endReference:requested.endReference,requiredEdition:requested.requiredEdition,passageStartReference:requested.endReference == nil ? requested.passageStartReference : requested.passageStartReference ?? match?.reference),
            text:stored.text,sectionCount:header.sectionCount,entries:header.entries,selection:selection,warning:stored.warning,
            content:stored.content,typography:typography,graphics:stored.graphics,inlineLinks:stored.inlineLinks,interlinearLines:stored.interlinearLines,passageParts:parts)
    }
}

/// Conversion writes a staging database, rereads every serialized section and
/// publishes it only after source hashes and SQLite integrity agree.
actor LibronNativeNormalizer {
    static let shared = LibronNativeNormalizer()
    private let encoder: JSONEncoder = { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }()
    func convert(_ resource: LibraryResource, progress: (@Sendable (Int,Int) -> Void)? = nil) async throws -> LibronNormalizationReceipt? {
        guard let package = resource.packageLocation, resource.format != .libronDictionary else { return nil }
        let sourceHash = try LibronPackage.hash(resource.location)
        guard sourceHash == (try LibronPackage.read(package).0.payload.sha256) else { throw LibronError.invalid("Original payload checksum mismatch") }
        let folder = package.appendingPathComponent("normalized")
        let target = folder.appendingPathComponent("reader.sqlite")
        let receiptURL = folder.appendingPathComponent("conversion.json")
        if FileManager.default.fileExists(atPath:target.path), let data = try? Data(contentsOf:receiptURL),
           let receipt = try? JSONDecoder().decode(LibronNormalizationReceipt.self,from:data),receipt.sourceSHA256 == sourceHash,receipt.state == "complete", receipt.converterVersion == 2 || resource.format != .eSwordSQLite {
            if [.legacyLSF,.libronixLLS].contains(resource.format), resource.libron?.resourceType == "Biblia", receipt.navigationVersion != 2 {
                return try await upgradeNavigation(resource,receipt:receipt,progress:progress)
            }
            if try LibronPackage.read(package).0.normalizedContent == nil { try LibronPackage.registerNormalizedContent(in:package) }
            return receipt
        }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let temporary = folder.appendingPathComponent("next-"+UUID().uuidString+".sqlite")
        defer { try? FileManager.default.removeItem(at:temporary) }
        var receipt = LibronNormalizationReceipt(resourceID:resource.id,sourceSHA256:sourceHash,state:"pending",profile:"",sections:0,checkedSections:0,warnings:[])
        do {
            let db = try LibronNativeDatabase(temporary,create:true)
            let legacy = resource.format == .legacyLSF || resource.format == .libronixLLS ? try await LibronLegacyImportSource(resource) : nil
            let esword = resource.format == .eSwordSQLite ? try ESwordResource.SequentialReader(resource.location) : nil
            let first: ReaderPage
            if let legacy { first = try await legacy.page(0) }
            else if let esword { first = try await ESwordReader.project(esword.page(0),request:.init(ordinal:0)) }
            else { first = try await ReaderSession.readOriginal(resource,.init(ordinal:0)) }
            guard first.sectionCount > 0 else { throw LibronError.invalid("Empty source directory") }
            let books = (try? await BibleChapterCatalog.shared.books(in:resource)) ?? []
            var header = LibronNativeHeader(resourceID:resource.id,sourceSHA256:sourceHash,sectionCount:first.sectionCount,
                profile:first.oeb == nil ? "structured-text" : "html",entries:first.entries,chapters:books)
            receipt.profile = header.profile;receipt.sections = first.sectionCount
            try db.put("header",data:encoder.encode(header))
            if let html = first.oeb {
                var members: [String:String] = [:]
                for (index,path) in html.book.members.keys.sorted().enumerated() {
                    let data = html.book.members[path]!, key = "html/member/\(index)"
                    if data.isEmpty { members[path] = ""; continue }
                    try db.put(key,data:data)
                    guard try db.get(key) == data else { throw LibronError.invalid("HTML member differs from source") }
                    members[path] = key
                }
                try db.put("html-index",data:encoder.encode(LibronNativeHTMLIndex(directory:html.book.directory,members:members)))
                receipt.checkedSections = first.sectionCount
            } else {
                var typographyKeys: Set<String> = []
                var legacyTypographyKey: String?
                var firstBibleOrdinal = 0
                if let book = books.first, let chapter = book.chapters.first,
                   let page = try? await ReaderSession.readOriginal(resource,.init(ordinal:0,reference:book.reference(chapter:chapter))) { firstBibleOrdinal = page.destination.ordinal }
                for ordinal in 0..<first.sectionCount {
                    try Task.checkCancellation()
                    let page: ReaderPage
                    if ordinal == 0 { page = first }
                    else if let legacy { page = try await legacy.page(ordinal) }
                    else if let esword { page = try await ESwordReader.project(esword.page(ordinal),request:.init(ordinal:ordinal)) }
                    else { page = try await ReaderSession.readOriginal(resource,.init(ordinal:ordinal)) }
                    guard page.oeb == nil, page.content?.plainText == nil || page.content?.plainText == page.text else { throw LibronError.invalid("Inconsistent normalized text projection") }
                    var key: String?
                    if legacy != nil, ordinal > 0 { key = legacyTypographyKey }
                    else if let typography = page.typography {
                        let data = try encoder.encode(typography)
                        key = "typography/" + SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
                        if typographyKeys.insert(key!).inserted { try db.put(key!,data:data) }
                        if legacy != nil { legacyTypographyKey = key }
                    }
                    var section = LibronNativeSection(text:page.text,content:page.content,typographyKey:key,graphics:page.graphics,
                        inlineLinks:page.inlineLinks,interlinearLines:page.interlinearLines,warning:page.warning)
                    if let legacy { section.referenceEnds = await legacy.referenceEnds(ordinal) }
                    let encoded = try encoder.encode(section);try db.put("section/\(ordinal)",data:encoded)
                    guard let checked = try db.get("section/\(ordinal)"), checked == encoded else { throw LibronError.invalid("Normalized section differs from source") }
                    if ordinal >= firstBibleOrdinal {
                        if let legacy {
                            for reference in await legacy.validReferences(section:section,ordinal:ordinal) { try db.add(reference:reference.0,ordinal:ordinal,offset:reference.1) }
                        }
                        else {
                            for anchor in page.content?.anchors ?? [] {
                                guard let reference = anchor.reference, anchor.characterOffset >= 0, anchor.characterOffset < page.text.utf16.count else { continue }
                                try db.add(reference:reference,ordinal:ordinal,offset:anchor.characterOffset)
                            }
                        }
                    }
                    if let warning = page.warning, receipt.warnings.count < 32, !receipt.warnings.contains(warning) { receipt.warnings.append(warning) }
                    receipt.checkedSections += 1;progress?(ordinal+1,first.sectionCount)
                }
            }
            if LibronDictionaryIndex.supports(resource) {
                let index = try await LibronDictionaryIndexService.shared.index(resource)
                try db.put("dictionary",data:encoder.encode(index.entries))
                for entry in index.entries {
                    guard (0..<first.sectionCount).contains(entry.ordinal) else { throw LibronError.invalid("Dictionary destination outside normalized content") }
                    try db.add(word:entry)
                }
                if header.entries.isEmpty {
                    header.entries = index.entries.enumerated().map { .init(id:$0.offset,ordinal:$0.element.ordinal,title:$0.element.headword) }
                    try db.put("header",data:encoder.encode(header))
                }
            }
            guard try LibronPackage.hash(resource.location) == sourceHash else { throw LibronError.invalid("Source changed during normalization") }
            try db.finish()
            // Publishing is atomic on this volume; the source payload is untouched.
            if FileManager.default.fileExists(atPath:target.path) {
                try LibronPackage.beginNormalizedUpdate(in:package)
                _ = try FileManager.default.replaceItemAt(target,withItemAt:temporary)
            }
            else { try FileManager.default.moveItem(at:temporary,to:target) }
            try LibronPackage.registerNormalizedContent(in:package)
            receipt.state = "complete"
            try encoder.encode(receipt).write(to:receiptURL,options:.atomic)
            return receipt
        } catch {
            receipt.state = "pending";receipt.warnings.append(error.localizedDescription)
            try? encoder.encode(receipt).write(to:receiptURL,options:.atomic)
            throw error
        }
    }
    private func upgradeNavigation(_ resource: LibraryResource, receipt original: LibronNormalizationReceipt,
        progress: (@Sendable (Int,Int) -> Void)?) async throws -> LibronNormalizationReceipt {
        guard let target = LibronNativeReader.location(resource), let package = resource.packageLocation else { throw RebuildError.unsupportedFormat }
        let temporary = target.deletingLastPathComponent().appendingPathComponent("next-"+UUID().uuidString+".sqlite")
        try FileManager.default.copyItem(at:target,to:temporary)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let db = try LibronNativeDatabase(temporary,edit:true)
        let source = try await LibronLegacyImportSource(resource)
        try db.clearReferences()
        for ordinal in 0..<original.sections {
            try Task.checkCancellation()
            guard let data = try db.get("section/\(ordinal)") else { throw LibronError.invalid("Missing normalized section") }
            var section = try JSONDecoder().decode(LibronNativeSection.self,from:data)
            section.referenceEnds = await source.referenceEnds(ordinal)
            try db.put("section/\(ordinal)",data:encoder.encode(section))
            for reference in await source.validReferences(section:section,ordinal:ordinal) { try db.add(reference:reference.0,ordinal:ordinal,offset:reference.1) }
            progress?(ordinal+1,original.sections)
        }
        guard try LibronPackage.hash(resource.location) == original.sourceSHA256 else { throw LibronError.invalid("Source changed during index conversion") }
        try db.finish()
        try LibronPackage.beginNormalizedUpdate(in:package)
        _ = try FileManager.default.replaceItemAt(target,withItemAt:temporary)
        try LibronPackage.registerNormalizedContent(in:package)
        var receipt = original;receipt.navigationVersion = 2
        try encoder.encode(receipt).write(to:package.appendingPathComponent("normalized/conversion.json"),options:.atomic)
        return receipt
    }

}

/// Reuses checked source directories, typography and image catalogs during a
/// full conversion, avoiding reparsing a complete index for every article.
private actor LibronLegacyImportSource {
    let inner: LibraryResource
    let service = LegacyContentService()
    let graphicService = LegacyGraphicsService()
    let first: ReaderPage
    let stamp: LegacyGraphicSourceStamp
    let extended: Bool
    let endings: [Int:[Int:Int]]
    let eligible: Set<Int>
    let firstBibleOrdinal: Int
    init(_ resource: LibraryResource) async throws {
        inner = resource.format == .libronixLLS ? try await LibronixBookService.shared.prepare(resource) : resource
        first = try await ReaderSession.readOriginal(resource,.init(ordinal:0))
        stamp = try LegacyGraphicsService.fileStamp(inner.location)
        extended = resource.format == .libronixLLS
        let positions = (try? await service.referencePositions(inner.location,indexURL:inner.indexLocation,allowUnavailableIndexBlocks:extended)) ?? []
        var ends: [Int:[Int:Int]] = [:]
        for position in positions {
            let ordinal = Int(position.startArticleID), offset = Int(position.startCharacterOffset)
            if ends[ordinal]?[offset] == nil { ends[ordinal,default:[:]][offset] = position.startArticleID == position.endArticleID ? Int(position.endCharacterOffset)+1 : -1 }
        }
        endings = ends
        eligible = Set((try? await service.navigationArticles(inner.location,indexURL:inner.indexLocation,allowUnavailableIndexBlocks:extended)) ?? [])
        if resource.libron?.resourceType == "Biblia", let book = try? await BibleChapterCatalog.shared.books(in:resource).first,
           let chapter = book.chapters.first, let page = try? await ReaderSession.readOriginal(resource,.init(ordinal:0,reference:book.reference(chapter:chapter))) {
            firstBibleOrdinal = page.destination.ordinal
        } else { firstBibleOrdinal = 0 }
    }
    func validReferences(section: LibronNativeSection, ordinal: Int) -> [(String,Int)] {
        guard ordinal >= firstBibleOrdinal, eligible.contains(ordinal) else { return [] }
        var seen: Set<String> = [], result: [(String,Int)] = []
        let anchors = section.content?.anchors ?? []
        for anchor in anchors {
            guard let reference = anchor.reference, let query = LegacyPassageQuery.sourceReference(reference),seen.insert(query.normalizedKey).inserted else { continue }
            let offset = anchor.characterOffset
            let next = anchors.first { $0.reference != nil && $0.characterOffset > offset && $0.reference.flatMap(LegacyPassageQuery.sourceReference)?.normalizedKey != query.normalizedKey }?.characterOffset ?? section.text.utf16.count
            let end = endings[ordinal]?[offset] ?? next
            guard offset >= 0, end >= offset, end <= next, end <= section.text.utf16.count else { continue }
            result.append((reference,offset))
        }
        return result
    }
    func referenceEnds(_ ordinal: Int) -> [Int:Int] { endings[ordinal] ?? [:] }
    func page(_ ordinal: Int) async throws -> ReaderPage {
        if ordinal == 0 { return first }
        let content = try await service.read(inner.location,ordinal:ordinal)
        let graphics = try await graphicService.load(inner.location,graphics:content.graphics,expectedSource:stamp)
        var links: [LegacyInlineLink] = [], warnings = graphics.warnings + content.warnings.filter { $0.hasPrefix("Recovered malformed closing reference metadata:") }
        do {
            let resolution = try await service.inlineLinks(inner.location,content:content,indexURL:inner.indexLocation,allowUnavailableIndexBlocks:extended)
            links = resolution.links
            if resolution.unresolvedAttributedRuns > 0 { warnings.append("Unresolved source links: \(resolution.unresolvedAttributedRuns)") }
        } catch is CancellationError { throw CancellationError() }
        catch { warnings.append("Source link index unavailable: "+error.localizedDescription) }
        return .init(destination:.init(ordinal:ordinal),text:content.plainText,sectionCount:first.sectionCount,entries:first.entries,
            warning:warnings.isEmpty ? nil : warnings.joined(separator:"\n"),content:content,typography:first.typography,
            graphics:graphics.assets,inlineLinks:links,interlinearLines:first.interlinearLines)
    }
}
