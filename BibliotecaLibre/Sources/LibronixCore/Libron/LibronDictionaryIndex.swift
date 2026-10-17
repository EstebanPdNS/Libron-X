import Foundation

public struct LibronDictionaryEntry: Codable, Sendable, Hashable {
    public var headword: String
    public var ordinal: Int
    public init(headword: String, ordinal: Int) { self.headword = headword; self.ordinal = ordinal }
}
public struct LibronDictionaryIndex: Codable, Sendable {
    public var schemaVersion = 1
    public var resourceID: String
    public var sourceStamp: String
    public var entries: [LibronDictionaryEntry]
    public static func supports(_ resource: LibraryResource) -> Bool {
        let metadata = LibronMetadata.deriving(resource)
        return ["Diccionario o enciclopedia", "Léxico"].contains(metadata.resourceType)
    }
    public static func key(_ text: String) -> String {
        text.replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
    public static func aliases(_ text: String) -> [String] {
        let clean = text.contains("<") ? text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression) : text
        var values = [clean]
        if clean.contains(where: { ",;\n\t".contains($0) }) {
            values += clean.components(separatedBy: CharacterSet(charactersIn: ",;\n\t"))
        }
        for value in values {
            if value.contains(" — ") { values += value.components(separatedBy: " — ") }
            if let boundary = value.firstIndex(where: { $0 == "(" || $0 == "[" }) { values.append(String(value[..<boundary])) }
        }
        for value in values {
            var alias = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if alias.first?.isNumber == true {
                let digits = alias.prefix(while: \.isNumber)
                let rest = alias.dropFirst(digits.count)
                if rest.first == "." || rest.first?.isWhitespace == true {
                    alias = String(rest.drop(while: { $0 == "." || $0.isWhitespace }))
                }
            }
            while alias.last == "." || alias.last == ":" { alias.removeLast() }
            if alias != value { values.append(alias) }
        }
        if let first = clean.first, "GHgh".contains(first) {
            let number = clean.dropFirst().filter { !$0.isWhitespace }
            if !number.isEmpty, number.allSatisfy(\.isNumber), let integer = Int(number) {
                values.append(String(first) + String(integer))
            }
        }
        return Array(Set(values.map(key).filter { !$0.isEmpty }))
    }
}

/// Rebuildable package-local word indexes point to checked source articles.
/// Original payloads and their reader coordinates remain unchanged.
public actor LibronDictionaryIndexService {
    public static let shared = LibronDictionaryIndexService()
    private let content = LegacyContentService()
    private var cache: [String: (String, LibronDictionaryIndex, [String: LibronDictionaryEntry])] = [:]
    public init() {}
    private func stamp(_ resource: LibraryResource) throws -> String {
        try [resource.location, resource.indexLocation].compactMap { $0 }.map { url in
            let s = try LegacyGraphicsService.fileStamp(url)
            return "\(s.size):\(s.modified.timeIntervalSince1970):\(s.fileNumber ?? 0)"
        }.joined(separator: "/")
    }
    public func index(_ resource: LibraryResource) async throws -> LibronDictionaryIndex {
        guard LibronDictionaryIndex.supports(resource) else { throw LibronError.invalid("Resource is not a dictionary") }
        let signature = try stamp(resource)
        #if canImport(CSQLite)
        if let package = resource.packageLocation {
            let native = package.appendingPathComponent("normalized/reader.sqlite")
            if FileManager.default.fileExists(atPath:native.path), let data = try LibronNativeDatabase(native).get("dictionary") {
                let entries = try JSONDecoder().decode([LibronDictionaryEntry].self,from:data)
                let index = LibronDictionaryIndex(resourceID:resource.id,sourceStamp:signature,entries:entries)
                return index
            }
        }
        #endif
        if resource.format == .libronDictionary {
            return .init(resourceID: resource.id, sourceStamp: signature, entries: try LibronDictionaryDatabase.entries(resource.location))
        }
        if let cached = cache[resource.id], cached.0 == signature { return cached.1 }
        let path = resource.packageLocation?.appendingPathComponent("dictionary-index.json")
        if let path, let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 * 1024,
           let data = try? Data(contentsOf: path), let saved = try? JSONDecoder().decode(LibronDictionaryIndex.self, from: data),
           saved.schemaVersion == 1, saved.resourceID == resource.id, saved.sourceStamp == signature,
           !saved.entries.isEmpty, saved.entries.count <= 500_000, saved.entries.allSatisfy({ $0.ordinal >= 0 && !$0.headword.isEmpty && $0.headword.utf8.count <= 4096 }) {
            remember(saved); return saved
        }
        var entries: [LibronDictionaryEntry] = []
        if resource.format == .eSwordSQLite {
            entries = try ESwordResource.page(resource.location, ordinal: 0).contents.enumerated().map { .init(headword: $0.element, ordinal: $0.offset) }
        } else {
            if resource.format == .libronixLLS, let catalog = try? await LibronixTopicCatalogService.shared.catalog(resource) {
                for (i, named) in catalog.indexes.enumerated() {
                    for (j, topic) in named.topics.enumerated() {
                        try Task.checkCancellation()
                        for article in try catalog.articles(index: i, topic: j) {
                            entries.append(.init(headword: topic.text, ordinal: article.sectionOrdinal))
                        }
                    }
                }
            }
            // Directory aliases also cover resources with no fullindex.dat.
            let source = resource.format == .libronixLLS ? try await LibronixBookService.shared.prepare(resource) : resource
            if let directory = try? await content.directory(source.location, indexURL: source.indexLocation,
                allowUnavailableIndexBlocks: resource.format == .libronixLLS) {
                entries += directory.entries.compactMap { entry in
                    guard let label = entry.title ?? entry.positionLabel else { return nil }
                    return .init(headword: label, ordinal: entry.sectionOrdinal)
                }
            }
            if entries.isEmpty {
                // Some grammar dictionaries have physical articles but no AIDX
                // titles. Index real source headings, never invented ordinals.
                let sections = try await content.inspect(source.location)
                guard sections.sections.count <= 10_000 else { throw LibronError.invalid("Dictionary has no bounded headword directory") }
                for section in sections.sections {
                    try Task.checkCancellation()
                    let page = try await content.read(source.location, ordinal: section.ordinal)
                    if let heading = page.plainText.components(separatedBy: .newlines)
                        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                        .first(where: { !$0.isEmpty }), heading.count <= 256 {
                        entries.append(.init(headword: heading, ordinal: section.ordinal))
                    }
                }
            }
        }
        var seen = Set<LibronDictionaryEntry>()
        entries = entries.filter { !$0.headword.isEmpty && $0.headword.utf8.count <= 4096 && seen.insert($0).inserted }
        guard !entries.isEmpty, entries.count <= 500_000, try stamp(resource) == signature else { throw LibronError.invalid("Dictionary source changed or exceeds the entry limit") }
        let result = LibronDictionaryIndex(resourceID: resource.id, sourceStamp: signature, entries: entries)
        if let path { try JSONEncoder().encode(result).write(to: path, options: .atomic) }
        remember(result); return result
    }
    private func remember(_ index: LibronDictionaryIndex) {
        var keys: [String: LibronDictionaryEntry] = [:]
        // Exact source labels take precedence over generated display aliases.
        for entry in index.entries { if keys[LibronDictionaryIndex.key(entry.headword)] == nil { keys[LibronDictionaryIndex.key(entry.headword)] = entry } }
        for entry in index.entries { for alias in LibronDictionaryIndex.aliases(entry.headword) where keys[alias] == nil { keys[alias] = entry } }
        cache[index.resourceID] = (index.sourceStamp, index, keys)
    }
    public func match(_ word: String, in resource: LibraryResource) async throws -> LibronDictionaryEntry? {
        #if canImport(CSQLite)
        if let package = resource.packageLocation {
            let native = package.appendingPathComponent("normalized/reader.sqlite")
            if FileManager.default.fileExists(atPath:native.path) { return try LibronNativeDatabase(native).match(word) }
        }
        #endif
        if resource.format == .libronDictionary { return try LibronDictionaryDatabase.match(word, at: resource.location) }
        _ = try await index(resource)
        return cache[resource.id]?.2[LibronDictionaryIndex.key(word)]
    }
}
