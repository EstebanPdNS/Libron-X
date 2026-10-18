import Foundation

public struct BibliographyReportLabels: Sendable {
    public var title="Bibliography"
    public var unknown="Unknown"
    public var scope="Scope"
    public var generated="Generated"
    public var resource="Resource"
    public var partial="Partial report"
    public var issue="Unresolved member"
    public var language="en"
    public var fields: [BibliographyField:String] = [.title:"Title",.originalTitle:"Original title",.subtitle:"Subtitle",.authors:"Authors",.contributors:"Contributors",
        .year:"Year",.originalYear:"Original year",.publisher:"Publisher",.edition:"Edition",.series:"Series",.languages:"Languages",.abbreviation:"Abbreviation"]
    public var certainties:[BibliographyCertainty:String] = [.declared:"Declared",.inferred:"Inferred",.unverified:"Unverified",.unknown:"Unknown"]
    public var scopes:[BibliographyScope.Kind:String] = [.library:"Whole library",.collections:"Collections",.selection:"Selection"]
    public var reasons:[BibliographyScopeIssue.Reason:String] = [.missingCollection:"Missing collection",.missingResource:"Missing resource",.changedIdentity:"Changed resource identity"]
    public init() {}
}
public enum BibliographyReportRenderer {
    public static func plainText(_ report:BibliographyReport,labels:BibliographyReportLabels = .init()) -> String {
        var lines=[labels.title,labels.scope + ": " + scopeTitle(report,labels),labels.generated + ": " + ISO8601DateFormatter().string(from:report.generatedAt),""]
        if !report.coverageComplete { lines.append(labels.partial);lines.append("") }
        for (index,entry) in report.entries.enumerated() {
            lines.append(String(index + 1) + ". " + value(entry.field(.title),labels) + certainty(entry.field(.title),labels))
            for field in entry.fields where field.field != .title {
                lines.append("  " + (labels.fields[field.field] ?? field.field.rawValue) + ": " + value(field,labels) + certainty(field,labels))
            }
            lines.append("  " + labels.resource + ": " + entry.fileName + " · " + entry.format.displayName + (entry.legacyIdentifier.map { " · " + $0 } ?? ""))
            lines.append("")
        }
        for issue in report.scope.issues {
            lines.append(labels.issue + ": " + issue.title + " · " + (labels.reasons[issue.reason] ?? issue.reason.rawValue))
        }
        return lines.joined(separator:"\n") + "\n"
    }
    public static func html(_ report:BibliographyReport,labels:BibliographyReportLabels = .init()) -> String {
        func e(_ value:String) -> String { escapeHTML(value) }
        var body="<h1>" + e(labels.title) + "</h1><p>" + e(labels.scope + ": " + scopeTitle(report,labels)) + "</p><p>" + e(labels.generated + ": " + ISO8601DateFormatter().string(from:report.generatedAt)) + "</p>"
        if !report.coverageComplete { body += "<p class=\"partial\">" + e(labels.partial) + "</p>" }
        body += "<ol>"
        for entry in report.entries {
            body += "<li><h2>" + e(value(entry.field(.title),labels)) + "</h2><dl>"
            for field in entry.fields {
                body += "<dt>" + e(labels.fields[field.field] ?? field.field.rawValue) + "</dt><dd>" + e(value(field,labels)) + " <small>" + e(labels.certainties[field.certainty] ?? field.certainty.rawValue) + "</small></dd>"
            }
            body += "<dt>" + e(labels.resource) + "</dt><dd>" + e(entry.fileName + " · " + entry.format.displayName + (entry.legacyIdentifier.map { " · " + $0 } ?? "")) + "</dd></dl></li>"
        }
        body += "</ol>"
        if !report.scope.issues.isEmpty {
            body += "<h2>" + e(labels.partial) + "</h2><ul>"
            for issue in report.scope.issues { body += "<li>" + e(issue.title + " · " + (labels.reasons[issue.reason] ?? issue.reason.rawValue)) + "</li>" }
            body += "</ul>"
        }
        return "<!doctype html><html lang=\"" + e(labels.language) + "\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\"><title>" + e(labels.title) + "</title><style>body{font:16px Georgia,serif;line-height:1.5;max-width:960px;margin:40px auto;padding:0 24px;color:#222;background:#fff}h2{font-size:1.1em}li{break-inside:avoid;margin-bottom:28px}dl{display:grid;grid-template-columns:150px 1fr;gap:5px 16px}dt{font-weight:bold}dd{margin:0;white-space:pre-wrap;overflow-wrap:anywhere}small{color:#666;margin-left:8px}.partial{font-weight:bold}@media print{body{margin:0}}</style></head><body>" + body + "</body></html>"
    }
    public static func json(_ report:BibliographyReport) throws -> Data {
        struct Document:Encodable {
            let schemaVersion:Int;let id:UUID;let generatedAt:Date;let scope:BibliographyScope
            let sourceFingerprint:String;let order:BibliographyOrder;let coverageComplete:Bool;let entries:[BibliographyEntry]
        }
        let value=Document(schemaVersion:report.schemaVersion,id:report.id,generatedAt:report.generatedAt,scope:report.scope,
            sourceFingerprint:report.sourceFingerprint,order:report.order,coverageComplete:report.coverageComplete,entries:report.entries)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes];encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    public static func scopeTitle(_ report:BibliographyReport,_ labels:BibliographyReportLabels) -> String {
        (labels.scopes[report.scope.kind] ?? report.scope.kind.rawValue) + (report.scope.names.isEmpty ? "" : " · " + report.scope.names.joined(separator:"; "))
    }
    private static func value(_ field:BibliographyFieldRecord,_ labels:BibliographyReportLabels) -> String { field.values.isEmpty ? labels.unknown : field.text }
    private static func certainty(_ field:BibliographyFieldRecord,_ labels:BibliographyReportLabels) -> String { " [" + (labels.certainties[field.certainty] ?? field.certainty.rawValue) + "]" }
    public static func escapeHTML(_ value:String) -> String {
        value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;")
            .replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&#39;")
    }
}
