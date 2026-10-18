import AppKit
import SwiftUI
import LibronixCore

@MainActor enum ResourceCitationActions {
    static var style: ResourceCitationStyle {
        get { ResourceCitationStyle(rawValue: UserDefaults.standard.string(forKey: "resourceCitationStyle") ?? "") ?? .catalog }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "resourceCitationStyle") }
    }
    static func entries(_ resources: [LibraryResource]) throws -> [BibliographyEntry] {
        try BibliographyReportGenerator.generate(resources: resources, scope: .init(kind: .selection, names: [], requestedCount: resources.count)).entries
    }
    static func copy(_ resources: [LibraryResource], pasteboard: NSPasteboard = .general) {
        guard !resources.isEmpty, let rows = try? entries(resources) else { return }
        let text = rows.map { ResourceCitation.text($0, style: style, unknown: L("Desconocido")) }.joined(separator: "\n")
        let html = "<html><body>" + rows.map { "<p>" + ResourceCitation.html($0, style: style, unknown: L("Desconocido")) + "</p>" }.joined() + "</body></html>"
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string); pasteboard.setString(html, forType: .html)
    }
}

struct ResourceCitationStylePicker: View {
    @AppStorage("resourceCitationStyle") private var style = ResourceCitationStyle.catalog.rawValue
    var body: some View {
        Picker(L("Estilo de cita"), selection: $style) {
            ForEach(ResourceCitationStyle.allCases, id: \.rawValue) { Text(L($0.title)).tag($0.rawValue) }
        }
    }
}

struct CitationPreview: View {
    let entry: BibliographyEntry
    @AppStorage("resourceCitationStyle") private var style = ResourceCitationStyle.catalog.rawValue
    var body: some View {
        Text(ResourceCitation.text(entry, style: ResourceCitationStyle(rawValue: style) ?? .catalog, unknown: L("Desconocido")))
            .textSelection(.enabled).font(.callout).frame(maxWidth:.infinity,alignment:.leading)
    }
}
