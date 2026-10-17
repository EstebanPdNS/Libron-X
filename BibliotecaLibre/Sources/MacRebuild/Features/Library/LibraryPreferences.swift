import AppKit
import Observation
import LibronixCore

enum LibraryField: String, CaseIterable, Identifiable, Codable {
    case title, author, language, type, category, subcategory, year, publisher, collection, edition, origin, tags, coverage, subtitle, contributors, originalYear, format, file
    var id: String { rawValue }
    var title: String {
        switch self {
        case .format: "Formato"; case .file: "Archivo"
        case .title: "Título"; case .author: "Autor"; case .language: "Idioma"; case .type: "Tipo"; case .category: "Categoría"
        case .subcategory: "Subcategorías"; case .year: "Año"; case .publisher: "Editorial"; case .collection: "Colección"
        case .edition: "Edición"; case .origin: "Origen"; case .tags: "Etiquetas"; case .coverage: "Cobertura bíblica"
        case .subtitle: "Subtítulo"; case .contributors: "Colaboradores"; case .originalYear: "Año original"
        }
    }
    @MainActor func value(_ r: LibraryResource) -> String {
        let m = LibronMetadata.deriving(r)
        switch self {
        case .format: return r.packageLocation == nil ? r.format.displayName : ".libron · " + r.format.displayName
        case .file: return r.fileName
        case .title: return m.title
        case .author: return m.authors.joined(separator: "; ")
        case .language: return m.languages.map { LibraryLanguages.name($0) }.joined(separator: ", ")
        case .type: return L(m.resourceType)
        case .category: return L(m.category)
        case .subcategory: return m.subcategories.joined(separator: ", ")
        case .year: return m.year ?? ""
        case .publisher: return m.publisher ?? ""
        case .collection: return m.collection ?? ""
        case .edition: return m.edition ?? ""
        case .origin: return m.origin
        case .tags: return m.tags.joined(separator: ", ")
        case .coverage: return m.biblicalCoverage ?? ""
        case .subtitle: return m.subtitle ?? ""
        case .contributors: return m.contributors.joined(separator: "; ")
        case .originalYear: return m.originalYear ?? ""
        }
    }
}
enum LibraryLanguages {
    static func canonical(_ code: String) -> String {
        let aliases = ["spa":"es","sp":"es","eng":"en","por":"pt","heb":"he","lat":"la","ger":"de","gre":"el"]
        return aliases[code.lowercased()] ?? code.lowercased()
    }
    @MainActor static func name(_ code: String) -> String {
        AppPreferences.shared.language.locale.localizedString(forLanguageCode: canonical(code)) ?? code
    }
    @MainActor static func searchNames(_ codes: [String]) -> String {
        codes.flatMap { code in
            ["es","en","pt",AppPreferences.shared.language.rawValue].compactMap { Locale(identifier: $0).localizedString(forLanguageCode: canonical(code)) } + [canonical(code)]
        }.joined(separator: " ")
    }
}
@MainActor @Observable final class LibraryPreferences {
    static let shared = LibraryPreferences()
    private let defaults: UserDefaults
    var askBeforeConversion: Bool { didSet { defaults.set(askBeforeConversion, forKey: "mac.libron.ask.v1") } }
    var backupOriginals: Bool { didSet { defaults.set(backupOriginals, forKey: "mac.libron.backup.v1") } }
    var columns: [LibraryField] { didSet { defaults.set(columns.map(\.rawValue), forKey: "mac.libron.columns.v1") } }
    var directory: URL { didSet { defaults.set(directory.path, forKey: "mac.libron.directory.v1") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        askBeforeConversion = defaults.object(forKey: "mac.libron.ask.v1") == nil ? true : defaults.bool(forKey: "mac.libron.ask.v1")
        backupOriginals = defaults.object(forKey: "mac.libron.backup.v1") == nil ? true : defaults.bool(forKey: "mac.libron.backup.v1")
        let savedColumns = defaults.stringArray(forKey: "mac.libron.columns.v1")?.compactMap(LibraryField.init(rawValue:)) ?? [.author,.type,.language,.category,.year,.origin]
        var seen = Set<LibraryField>(); columns = savedColumns.filter { $0 != .title && seen.insert($0).inserted }
        directory = defaults.string(forKey: "mac.libron.directory.v1").map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("org.libronx.mac.rebuild/Library", isDirectory: true)
    }
    func toggleColumn(_ field: LibraryField) {
        if columns.contains(field) { columns.removeAll { $0 == field } } else { columns.append(field) }
    }
}
