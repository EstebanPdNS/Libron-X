import Foundation
import LibronixCore

/// Rules use catalog metadata only; evaluating membership never opens or changes a book.
struct LibraryCollectionRule: Codable, Equatable, Sendable {
    enum Match: String, Codable, CaseIterable, Sendable {
        case all, any
        @MainActor var title: String { L(self == .all ? "Todas las condiciones" : "Cualquier condición") }
    }
    enum Field: String, Codable, CaseIterable, Sendable {
        case title, author, language, format, resourceType, category, tag, publisher, year, series, origin, fileName
        case subtitle, contributor, edition, originalYear, coverage, subcategory, abbreviation
        @MainActor var title: String {
            switch self {
            case .title: L("Título")
            case .author: L("Autor")
            case .language: L("Idioma")
            case .format: L("Formato")
            case .resourceType: L("Tipo de recurso")
            case .category: L("Categoría")
            case .tag: L("Etiqueta")
            case .publisher: L("Editorial")
            case .year: L("Año")
            case .series: L("Serie")
            case .origin: L("Origen")
            case .fileName: L("Archivo")
            case .subtitle: L("Subtítulo")
            case .contributor: L("Colaboradores")
            case .edition: L("Edición")
            case .originalYear: L("Año original")
            case .coverage: L("Cobertura bíblica")
            case .subcategory: L("Subcategorías")
            case .abbreviation: L("Abreviatura")
            }
        }
        func values(_ resource: LibraryResource) -> [String] {
            let metadata = LibronMetadata.deriving(resource)
            switch self {
            case .title: return [metadata.title, metadata.originalTitle, metadata.subtitle, metadata.abbreviation].compactMap { $0 }
            case .author: return metadata.authors
            case .language: return metadata.languages.map(LibraryLanguages.canonical)
            case .format: return [resource.format.rawValue, resource.format.displayName]
            case .resourceType: return [metadata.resourceType]
            case .category: return [metadata.category] + metadata.subcategories
            case .tag: return metadata.tags
            case .publisher: return [metadata.publisher].compactMap { $0 }
            case .year: return [metadata.year].compactMap { $0 }
            case .series: return [metadata.collection].compactMap { $0 }
            case .origin: return [metadata.origin]
            case .fileName: return [resource.location.lastPathComponent, resource.fileName]
            case .subtitle: return [metadata.subtitle].compactMap { $0 }
            case .contributor: return metadata.contributors
            case .edition: return [metadata.edition].compactMap { $0 }
            case .originalYear: return [metadata.originalYear].compactMap { $0 }
            case .coverage: return [metadata.biblicalCoverage].compactMap { $0 }
            case .subcategory: return metadata.subcategories
            case .abbreviation: return [metadata.abbreviation].compactMap { $0 }
            }
        }
    }
    enum Operation: String, Codable, CaseIterable, Sendable {
        case contains, equals, startsWith, notContains, notEquals, exists, missing
        var needsValue: Bool { self != .exists && self != .missing }
        @MainActor var title: String {
            switch self {
            case .contains: L("Contiene")
            case .equals: L("Es igual a")
            case .startsWith: L("Empieza por")
            case .notContains: L("No contiene")
            case .notEquals: L("No es igual a")
            case .exists: L("Tiene valor")
            case .missing: L("Sin valor")
            }
        }
    }
    struct Condition: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var field = Field.title
        var operation = Operation.contains
        var value = ""
        func matches(_ resource: LibraryResource) -> Bool {
            let values = field.values(resource).map(LibraryCollectionRule.normalized).filter { !$0.isEmpty }
            if operation == .exists { return !values.isEmpty }
            if operation == .missing { return values.isEmpty }
            // Unknown metadata cannot establish a positive or negative comparison.
            guard !values.isEmpty else { return false }
            let target = LibraryCollectionRule.normalized(field == .language ? LibraryLanguages.canonical(value) : value)
            switch operation {
            case .contains: return values.contains { $0.contains(target) }
            case .equals: return values.contains(target)
            case .startsWith: return values.contains { $0.hasPrefix(target) }
            case .notContains: return !values.contains { $0.contains(target) }
            case .notEquals: return !values.contains(target)
            case .exists, .missing: return false
            }
        }
    }
    var match = Match.all
    var conditions: [Condition] = [.init()]
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    func validate() throws {
        guard (1...32).contains(conditions.count), Set(conditions.map(\.id)).count == conditions.count,
              conditions.allSatisfy({ condition in
                  condition.value.utf16.count <= 512 && !condition.value.contains("\0") &&
                  (!condition.operation.needsValue || !Self.normalized(condition.value).isEmpty)
              }) else {
            throw PersonalStateError.invalid(AppStrings.text("Las reglas necesitan entre 1 y 32 condiciones válidas.", language: .saved()))
        }
    }
    func matches(_ resource: LibraryResource) -> Bool {
        guard !conditions.isEmpty else { return false }
        switch match {
        case .all: return conditions.allSatisfy { $0.matches(resource) }
        case .any: return conditions.contains { $0.matches(resource) }
        }
    }
}
extension LibraryCollection {
    func resolvedMembers(in resources: [LibraryResource]) -> [LibraryCollectionMember] {
        guard let rule else { return members }
        return resources.filter(rule.matches).sorted { $0.id < $1.id }.map(LibraryCollectionMember.init)
    }
    func contains(_ resource: LibraryResource) -> Bool {
        if let rule { return rule.matches(resource) }
        return members.contains { $0.resolve(in: [resource]) != nil }
    }
}
