import Foundation

public enum LibronBibliography {
    /// Only explicitly declared bibliographic fields receive embedded credit.
    public static func enrich(_ resource: LibraryResource) -> LibronMetadata {
        if let metadata = resource.libron, resource.packageLocation != nil { return metadata }
        var m = LibronMetadata.deriving(resource)
        func record(_ field: String, _ value: String?, assign: (String) -> Void) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            assign(value); m.evidence.append(.init(field: field, value: value, source: "embedded:" + resource.fileName))
        }
        if resource.format == .legacyLSF, let legacy = try? LegacyResourceReader.inspect(lsfURL: resource.location).lsf {
            m.publisher = legacy.publisher
            if let publication = legacy.publication {
                m.originalInformation = publication
                if let range = publication.range(of: #"\b(?:1[4-9]|20)[0-9]{2}\b"#, options: .regularExpression) {
                    m.year = String(publication[range]); m.evidence.append(.init(field: "year", value: m.year!, source: "embedded:publication", status: "inferred"))
                }
            }
            if legacy.uniformTitle?.lowercased().hasPrefix("bible") == true || legacy.uniformTitle?.lowercased().hasPrefix("biblia") == true {
                m.resourceType = "Biblia"; m.category = "Biblias y texto bíblico"
            }
        }
        if [.libronixLLS,.libronixOEB].contains(resource.format), let book = try? LibronixBookArchive.inspect(at: resource.location).metadata() {
            func flatten(_ node: XMLNode) -> [XMLNode] { [node] + node.children.flatMap(flatten) }
            let fields = flatten(book.xml).filter { $0.name == "meta" || $0.name == "dc-element" }
            func values(_ name: String) -> [String] { fields.filter { $0.attributes["name"]?.lowercased() == name }.map(\.text).filter { !$0.isEmpty } }
            m.publisher = values("dc.publisher").first ?? m.publisher
            m.year = values("dc.date").first ?? m.year
            m.tags = values("dc.subject") + values("dc.subject:lcsh")
            m.contributors = values("dc.contributor.personalname")
            m.edition = values("dc.description.edition").first
            m.collection = values("dc.relation.ispartof").first
            let types = values("dc.type:lbx-types").joined(separator: " ").lowercased()
            if types.contains("text.monograph.bible") && !types.contains("commentary") {
                m.resourceType = "Biblia"; m.category = "Biblias y texto bíblico"
            } else if types.contains("commentary") { m.resourceType = "Comentario bíblico"; m.category = "Estudios bíblicos" }
            else if types.contains("dictionary") { m.resourceType = "Diccionario o enciclopedia" }
            else if types.contains("lexicon") { m.resourceType = "Léxico"; m.category = "Lenguas bíblicas" }
            m.originalInformation = String(data: (try? JSONEncoder().encode(book.xml)) ?? Data(), encoding: .utf8)
        }
        // Topic classification is explicitly an inference, separate from bibliography.
        let title = m.title.folding(options: [.caseInsensitive,.diacriticInsensitive], locale: Locale(identifier: "es"))
        let rules: [(String, [String])] = [
            ("Ministerio e iglesia", ["lider", "equipo", "iglesia local", "pastor", "discipul", "leadership"]),
            ("Misiones y evangelización", ["mision", "evangeli", "comibam", "musulman"]),
            ("Consejería y cuidado pastoral", ["consejer", "matrimonio", "familia", "salud integral"]),
            ("Historia del cristianismo", ["historia del crist", "historia de la iglesia", "church history"]),
            ("Interpretación bíblica", ["hermene", "exeges", "interpretacion"]),
            ("Lenguas bíblicas", ["hebreo", "griego", "greek", "hebrew", "morfolog", "morpholog"]),
            ("Vida cristiana y espiritualidad", ["oracion", "espiritual", "devoc", "gracia", "adoracion"])]
        if m.resourceType != "Biblia", m.resourceType != "Comentario bíblico" {
            for (category, words) in rules where words.contains(where: title.contains) { m.category = category; break }
        }
        if title.hasPrefix("estudios biblicos ela") { m.resourceType = "Manual o curso"; m.category = "Estudios bíblicos"; m.collection = "Estudios Bíblicos ELA" }
        if title.contains("lexicon") || title.hasPrefix("lexico") { m.resourceType = "Léxico" }
        if title.contains("concordancia") || title.contains("concordance") { m.resourceType = "Concordancia" }
        if title.contains("gramatica") || title.contains("grammar") { m.resourceType = "Gramática" }
        if title.contains("mapas") || title.contains("map collection") || title.contains("atlas") { m.resourceType = "Atlas"; m.category = "Historia y contexto bíblico" }
        if m.resourceType == "Diccionario o enciclopedia" {
            m.subcategories = Array(Set(m.subcategories + [m.category])).sorted()
            m.category = "Diccionarios y enciclopedias"
        }
        if resource.isHelp { m.resourceType = "Manual o curso"; m.category = "Ayuda de software" }
        let aliases = ["spa":"es","sp":"es","eng":"en","heb":"he","grc":"grc","gre":"el","lat":"la","ger":"de","por":"pt"]
        m.languages = m.languages.flatMap { code -> [String] in
            if code.count > 3, code.count % 3 == 0 {
                let units = Array(code)
                return stride(from: 0, to: units.count, by: 3).map { at in
                    let part = String(units[at..<at + 3]); return aliases[part] ?? part
                }
            }
            return [aliases[code] ?? code]
        }
        m.languages = Array(Set(m.languages)).sorted()
        record("publisher", m.publisher) { _ in }
        record("year", m.year) { _ in }
        let known = ["authors": !m.authors.isEmpty, "year": m.year != nil, "publisher": m.publisher != nil, "languages": !m.languages.isEmpty, "edition": m.edition != nil]
        m.pendingFields = known.filter { !$0.value }.keys.sorted()
        return m
    }
}
