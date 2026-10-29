import Foundation

/// An owned Bible preference, separate from original XML attributes and verse locations.
/// A same-named replacement or a different format is never silently substituted.
public struct StudyBibleEdition: Codable, Hashable, Sendable {
    public let resourceID: String
    public let title: String
    public let format: ResourceFormat
    public let legacyIdentifier: String?

    public init(_ resource: LibraryResource) {
        resourceID = resource.id; title = resource.title
        format = resource.format; legacyIdentifier = resource.legacyIdentifier
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.resourceID == rhs.resourceID && lhs.format == rhs.format && lhs.legacyIdentifier == rhs.legacyIdentifier
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(resourceID); hasher.combine(format); hasher.combine(legacyIdentifier)
    }

    public func resolve(in resources: [LibraryResource]) -> LibraryResource? {
        resources.first { $0.id == resourceID && $0.format == format && $0.legacyIdentifier == legacyIdentifier }
    }

    func validate() throws {
        guard !resourceID.isEmpty, !resourceID.contains("\0"), resourceID.utf8.count <= 16_384,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 4096,
              (legacyIdentifier?.utf8.count ?? 0) <= 1024 else {
            throw PersonalStateError.invalid("La edición guardada contiene una identidad inválida.")
        }
    }
}

/// Retained source compatibility for the first verse-list API.
public typealias StudyVerseListEdition = StudyBibleEdition
