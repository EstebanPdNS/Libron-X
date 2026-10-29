import Foundation
import LibronixCore

struct LibraryHealthIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case missingResource, invalidResource, opaqueResource, resourceWarning, missingAnnotationSource, unresolvedAnnotation }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
}
struct LibraryHealthReport: Equatable, Sendable {
    let resourceCount: Int
    let issues: [LibraryHealthIssue]
    let omittedIssueCount: Int
    static func inspect(resources: [LibraryResource], documents: [StudyDocument], highlights: [ReaderHighlight],
                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Self {
        let limit = 5000
        var issues: [LibraryHealthIssue] = [], omitted = 0
        func add(_ issue: LibraryHealthIssue) {
            if issues.count < limit { issues.append(issue) } else { omitted += 1 }
        }
        for (resourceIndex, resource) in resources.enumerated() {
            if Task.isCancelled { break }
            let paths = Set([resource.packageLocation, resource.location].compactMap { $0 })
            for path in paths.sorted(by: { $0.path < $1.path }) where !exists(path) {
                add(.init(id: "missing:\(resourceIndex):" + resource.id + ":" + path.path, kind: .missingResource, title: resource.title, detail: path.path))
            }
            if resource.support == .invalidFile {
                add(.init(id: "invalid:\(resourceIndex):" + resource.id, kind: .invalidResource, title: resource.title, detail: resource.format.displayName))
            }
            if resource.support == .opaqueContainer {
                add(.init(id: "opaque:\(resourceIndex):" + resource.id, kind: .opaqueResource, title: resource.title, detail: resource.format.displayName))
            }
            for (index, warning) in resource.warnings.enumerated() {
                add(.init(id: "warning:\(resourceIndex):" + resource.id + ":" + String(index), kind: .resourceWarning, title: resource.title, detail: warning))
            }
        }
        let resourceIDs = Set(resources.map(\.id))
        struct Identity: Hashable { let id: String; let format: ResourceFormat; let legacy: String? }
        let identities = Set(resources.map { Identity(id: $0.id, format: $0.format, legacy: $0.legacyIdentifier) })
        for document in documents {
            if Task.isCancelled { break }
            for note in document.notes {
                if Task.isCancelled { break }
                if note.resolvedAnchor == nil && (note.anchor.kind == .legacySelection || note.anchor.kind == .legacyReference) {
                    add(.init(id: "unresolved-note:" + document.id.uuidString + ":" + note.id.uuidString,
                              kind: .unresolvedAnnotation, title: note.title, detail: document.title))
                }
                guard let location = note.effectiveAnchor.location,
                      !identities.contains(Identity(id: location.resourceID, format: location.format, legacy: location.legacyIdentifier)) else { continue }
                add(.init(id: "note:" + document.id.uuidString + ":" + note.id.uuidString,
                          kind: .missingAnnotationSource, title: note.title, detail: document.title))
            }
        }
        for mark in highlights where !resourceIDs.contains(mark.resourceID) {
            if Task.isCancelled { break }
            add(.init(id: "highlight:" + mark.id.uuidString, kind: .missingAnnotationSource,
                      title: mark.resourceID, detail: ""))
        }
        return .init(resourceCount: resources.count, issues: issues, omittedIssueCount: omitted)
    }
}
