import Foundation

public struct WorkspaceSearchState: Codable, Equatable, Sendable {
    public var query = ""
    public var allResources = false
    public var caseSensitive = false
    public var diacriticSensitive = true
    public var wholeWords = true
    public var unit = "article"
    public init() {}
}

public struct WorkspaceWindowState: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var location: ReaderLocation?
    public var selectedResourceID: String?
    public var section = "all"
    public var catalogQuery = ""
    public var catalogFormat: ResourceFormat?
    public var catalogSort = "title"
    public var readerTab = "information"
    public var selectedDocumentID: UUID?
    public var selectedNoteID: UUID?
    public var linkGroup = ReaderLinkGroup.none
    public var history = ReadingHistory()
    public var search = WorkspaceSearchState()
    public var frame: [Double]?
    public init() {}
}

public struct WorkspaceDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var name: String
    public var windows: [WorkspaceWindowState]
    public init(name: String, windows: [WorkspaceWindowState]) { self.name = name; self.windows = windows }
    public func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 4_096,
              !windows.isEmpty, windows.count <= 100, Set(windows.map(\.id)).count == windows.count else {
            throw PersonalStateError.invalid("El espacio de trabajo necesita un nombre y entre 1 y 100 ventanas distintas.")
        }
        for window in windows {
            guard window.location.map({ $0.sectionOrdinal >= 0 }) ?? true,
                  window.history.current == nil || window.location == nil || window.history.current == window.location?.sectionOrdinal,
                  ["all", "recovered", "help", "collections", "search", "favorites", "documents"].contains(window.section),
                  ["title", "author", "format"].contains(window.catalogSort),
                  ["information", "preview"].contains(window.readerTab),
                  ["article", "bibleVerse"].contains(window.search.unit),
                  window.frame.map({ $0.count == 4 && $0.allSatisfy(\.isFinite) && $0[2] >= 200 && $0[3] >= 200 }) ?? true else {
                throw PersonalStateError.invalid("Una ventana del espacio de trabajo tiene un estado incompatible.")
            }
        }
    }
}
