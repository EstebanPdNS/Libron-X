import Foundation
import SwiftUI

/// Notes travel with the application and are matched to the installed version,
/// never to the latest remote release or the user's selected update channel.
struct InstalledReleaseNotes: Decodable, Equatable, Sendable {
    let version: String
    let changes: [String]
    static let bundled: [Self] = {
        guard let url = AppStrings.resourceBundle.url(forResource: "ReleaseNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return notes
    }()
    static func current(version: String) -> Self? { bundled.first { $0.version == version } }
}

struct InstalledReleaseNotesView: View {
    let version: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(version).font(.headline).textSelection(.enabled)
            if let notes = InstalledReleaseNotes.current(version: version) {
                ForEach(notes.changes, id: \.self) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(L(change)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }.font(.callout)
                }
            } else {
                Text(L("No hay un registro de cambios incluido para esta versión."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
