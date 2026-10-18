import Foundation

public enum ResourceCitationStyle: String, CaseIterable, Codable, Sendable {
    case catalog, chicagoAuthorDate, mla
    public var title: String { switch self { case .catalog: "Catálogo"; case .chicagoAuthorDate: "Chicago · autor–fecha"; case .mla: "MLA" } }
}

/// Basic book references from the catalog snapshot. No lookup, inferred date,
/// place, contributor role or fabricated pagination is added to a citation.
public enum ResourceCitation {
    public static func text(_ entry: BibliographyEntry, style: ResourceCitationStyle, unknown: String = "Unknown", noDate: String = "n.d.") -> String {
        func value(_ field: BibliographyField) -> String { entry.field(field).text.trimmingCharacters(in: .whitespacesAndNewlines) }
        func sentence(_ value: String) -> String { value.isEmpty ? "" : value + (value.last.map { ".!?".contains($0) } == true ? "" : ".") }
        let authors = entry.field(.authors).values
        let title = [value(.title).isEmpty ? unknown : value(.title), value(.subtitle)].filter { !$0.isEmpty }.joined(separator: ": ")
        let year = value(.year), publisher = value(.publisher), edition = value(.edition)
        let author: String
        if style == .mla, authors.count > 2 { author = authors[0] + ", et al." }
        else if authors.count > 1 {
            let rest = authors.dropFirst().map { name -> String in
                let parts = name.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 ? parts[1] + " " + parts[0] : name
            }
            author = ([authors[0]] + rest.dropLast()).joined(separator: ", ") + (authors.count == 2 ? " and " : ", and ") + rest.last!
        } else { author = authors.first ?? "" }
        switch style {
        case .catalog:
            return [sentence(author), sentence(title), sentence(edition), sentence([publisher, year].filter { !$0.isEmpty }.joined(separator: ", "))].filter { !$0.isEmpty }.joined(separator: " ")
        case .chicagoAuthorDate:
            return [sentence(author), sentence(year.isEmpty ? noDate : year), sentence(title), sentence(edition), sentence(publisher)].filter { !$0.isEmpty }.joined(separator: " ")
        case .mla:
            let institutional = authors.count == 1 && author.caseInsensitiveCompare(publisher) == .orderedSame
            let tail = [edition, publisher, year].filter { !$0.isEmpty }.joined(separator: ", ")
            return [institutional ? "" : sentence(author), sentence(title), sentence(tail)].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }
    public static func html(_ entry: BibliographyEntry, style: ResourceCitationStyle, unknown: String = "Unknown", noDate: String = "n.d.") -> String {
        // Escape source metadata before introducing our own title emphasis.
        let citation = BibliographyReportRenderer.escapeHTML(text(entry, style: style, unknown: unknown, noDate: noDate))
        let title = [entry.field(.title).text.isEmpty ? unknown : entry.field(.title).text, entry.field(.subtitle).text].filter { !$0.isEmpty }.joined(separator: ": ")
        let escaped = BibliographyReportRenderer.escapeHTML(title)
        guard let range = citation.range(of: escaped) else { return citation }
        return String(citation[..<range.lowerBound]) + "<i>" + escaped + "</i>" + String(citation[range.upperBound...])
    }
}
