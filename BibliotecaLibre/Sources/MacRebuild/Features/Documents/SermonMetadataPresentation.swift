import SwiftUI
import LibronixCore

@MainActor enum SermonMetadataPresentation {
    static func rows(_ metadata: SermonMetadata) -> [(key: String, value: String)] {
        [("Fecha", metadata.dateText), ("Predicador", metadata.speaker), ("Serie", metadata.series),
         ("Lugar", metadata.venue), ("Pasajes bíblicos", metadata.passages.joined(separator: " · ")),
         ("Etiquetas", metadata.tags.joined(separator: ", "))].filter { !$0.1.isEmpty }
    }
}
struct SermonMetadataSummary: View {
    let metadata: SermonMetadata
    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(Array(SermonMetadataPresentation.rows(metadata).enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(L(row.key)).foregroundStyle(.secondary)
                    Text(verbatim: row.value).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.font(.caption).textSelection(.enabled)
    }
}
@MainActor extension StudyDocumentKind {
    var symbol: String {
        switch self { case .notebook: "note.text"; case .verseList: "list.bullet"; case .sermon: "text.bubble" }
    }
}
