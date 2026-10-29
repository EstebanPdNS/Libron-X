import Foundation
import LibronixCore

enum MarkColor: String, Codable, CaseIterable, Hashable, Sendable { case yellow, green, blue, pink }

struct MarkPalette: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var colors: [MarkColor]
}

struct MarkPalettes: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var selectedID: UUID?
    var palettes: [MarkPalette] = []
    func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard palettes.count <= 100, Set(palettes.map(\.id)).count == palettes.count,
              selectedID == nil || palettes.contains(where: { $0.id == selectedID }),
              palettes.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  $0.name.utf8.count <= 1024 && !$0.colors.isEmpty && Set($0.colors).count == $0.colors.count }) else {
            throw PersonalStateError.invalid("La paleta de marcación no es válida.")
        }
    }
    var selectedColors: [MarkColor] { palettes.first(where: { $0.id == selectedID })?.colors ?? MarkColor.allCases }
}
