import Foundation

/// Bibliographic values never use the interface language as the book language.
public struct LibronEvidence: Codable, Hashable, Sendable {
    public var field: String
    public var value: String
    public var source: String
    public var status: String
    public init(field: String, value: String, source: String, status: String = "verified") {
        self.field = field; self.value = value; self.source = source; self.status = status
    }
}
public struct LibronMetadata: Codable, Hashable, Sendable {
    public var title: String
    public var subtitle: String? = nil
    public var authors: [String] = []
    public var contributors: [String] = []
    public var resourceType: String = "Monografía"
    public var category: String = "Referencia general"
    public var subcategories: [String] = []
    public var tags: [String] = []
    public var languages: [String] = []
    public var year: String? = nil
    public var originalYear: String? = nil
    public var publisher: String? = nil
    public var collection: String? = nil
    public var edition: String? = nil
    public var biblicalCoverage: String? = nil
    public var origin: String
    public var abbreviation: String? = nil
    public var originalTitle: String? = nil
    public var originalInformation: String? = nil
    public var evidence: [LibronEvidence] = []
    public var pendingFields: [String] = []
    public init(title: String, origin: String) { self.title = title; self.origin = origin }
    public static func deriving(_ resource: LibraryResource) -> Self {
        if let metadata = resource.libron { return metadata }
        var m = Self(title: resource.title, origin: resource.format == .legacyLSF || resource.format == .logosModern ? "Logos" : resource.format == .epub ? "EPUB" : resource.format == .eSwordSQLite ? "e-Sword" : "Libronix")
        m.authors = resource.author.map { [$0] } ?? []; m.languages = resource.languages
        let title = resource.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
        if title.contains("diccionario") || title.contains("dictionary") || title.contains("encyclop") { m.resourceType = "Diccionario o enciclopedia" }
        if title.contains("comentario") || title.contains("commentary") { m.resourceType = "Comentario bíblico"; m.category = "Estudios bíblicos" }
        if title.contains("biblia") || title.contains("bible") || title.contains("testament") { m.category = "Estudios bíblicos" }
        if title.contains("teolog") || title.contains("theolog") || title.contains("catecismo") { m.category = "Teología" }
        if title.contains("sermon") { m.resourceType = "Sermonario o bosquejos"; m.category = "Predicación y comunicación" }
        if title.contains("devoc") { m.resourceType = "Devocional"; m.category = "Vida cristiana y espiritualidad" }
        if title.contains("lexic") || title.contains("morpholog") || title.contains("grammar") { m.category = "Lenguas bíblicas" }
        m.evidence = [.init(field: "title", value: m.title, source: "embedded:" + resource.fileName)]
        m.evidence.append(.init(field: "category", value: m.category, source: "title-rule-v1", status: "inferred"))
        m.pendingFields = ["year", "publisher", "edition"]
        if m.authors.isEmpty { m.pendingFields.append("authors") }; if m.languages.isEmpty { m.pendingFields.append("languages") }
        return m
    }
    public var searchText: String {
        var values = [title, originalTitle ?? "", abbreviation ?? "", subtitle ?? "", resourceType, category, origin, year ?? "", originalYear ?? "", publisher ?? "", collection ?? "", edition ?? "", biblicalCoverage ?? ""]
        values.append(contentsOf: authors)
        values.append(contentsOf: contributors)
        values.append(contentsOf: languages)
        values.append(contentsOf: subcategories)
        values.append(contentsOf: tags)
        return values.joined(separator: " ")
    }
}
