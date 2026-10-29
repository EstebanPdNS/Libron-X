import Foundation
import LibronixCore

struct LibraryHealthIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case missingResource, invalidResource, opaqueResource, resourceWarning, missingAnnotationSource, unresolvedAnnotation, conversionIssue, unresolvedLink, damagedIndex, indexUnavailable }
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
                        favorites: [LibraryFavorite] = [], bookmarks: [Int: ReaderLocation] = [:],
                        plans: [ReadingPlan] = [], memoryCards: [ScriptureMemoryCard] = [], excerpts: [ResearchExcerpt] = [],
                        collections: [LibraryCollection] = [], associations: [ResourceAssociationSet] = [],
                        indexDirectory: URL? = nil,
                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Self {
        let limit = 5000
        var issues: [LibraryHealthIssue] = [], omitted = 0
        let indexDeadline = Date().addingTimeInterval(8)
        var reportedIndexTimeout = false
        func add(_ issue: LibraryHealthIssue) {
            if issues.count < limit { issues.append(issue) } else { omitted += 1 }
        }
        for (resourceIndex, resource) in resources.enumerated() {
            if Task.isCancelled { break }
            let paths = Set([resource.packageLocation, resource.location, resource.indexLocation].compactMap { $0 })
            for path in paths.sorted(by: { $0.path < $1.path }) where !exists(path) {
                add(.init(id: "missing:\(resourceIndex):" + resource.id + ":" + path.path, kind: .missingResource, title: resource.title, detail: path.path))
            }
            let remaining = indexDeadline.timeIntervalSinceNow
            if remaining > 0 {
                switch LibrarySearchIndexHealth.inspect(resource: resource, directory: indexDirectory, seconds: min(1, remaining)) {
                case .damaged:
                    add(.init(id: "index:\(resourceIndex):" + resource.id, kind: .damagedIndex, title: resource.title, detail: ""))
                case .unavailable:
                    add(.init(id: "index:\(resourceIndex):" + resource.id, kind: .indexUnavailable, title: resource.title, detail: ""))
                case .absent, .healthy: break
                }
            } else if !reportedIndexTimeout {
                reportedIndexTimeout = true
                add(.init(id: "index-budget", kind: .indexUnavailable, title: resource.title, detail: ""))
            }
            if resource.support == .invalidFile {
                add(.init(id: "invalid:\(resourceIndex):" + resource.id, kind: .invalidResource, title: resource.title, detail: resource.format.displayName))
            }
            if resource.support == .opaqueContainer {
                add(.init(id: "opaque:\(resourceIndex):" + resource.id, kind: .opaqueResource, title: resource.title, detail: resource.format.displayName))
            }
            if let package = resource.packageLocation {
                let folder = package.appendingPathComponent("normalized", isDirectory: true)
                let receiptURL = folder.appendingPathComponent("conversion.json")
                let databaseURL = folder.appendingPathComponent("reader.sqlite")
                if exists(receiptURL) {
                    let attributes = try? receiptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    let data = (attributes?.isRegularFile == true && attributes?.isSymbolicLink != true && (attributes?.fileSize ?? Int.max) <= 4 * 1024 * 1024) ? try? Data(contentsOf: receiptURL) : nil
                    let receipt = data.flatMap { try? JSONDecoder().decode(LibronNormalizationReceipt.self, from: $0) }
                    let manifest = try? LibronPackage.read(package).0
                    if receipt?.state != "complete" || receipt?.resourceID != resource.id || receipt?.sourceSHA256 != manifest?.payload.sha256 ||
                        (receipt?.sections ?? 0) <= 0 || receipt?.checkedSections != receipt?.sections || !exists(databaseURL) {
                        add(.init(id: "conversion:\(resourceIndex):" + resource.id, kind: .conversionIssue, title: resource.title, detail: receiptURL.path))
                    }
                } else if exists(databaseURL) {
                    add(.init(id: "conversion:\(resourceIndex):" + resource.id, kind: .conversionIssue, title: resource.title, detail: receiptURL.path))
                }
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
            for verse in document.verses {
                if Task.isCancelled { break }
                if let location = verse.location, !identities.contains(Identity(id: location.resourceID, format: location.format, legacy: location.legacyIdentifier)) {
                    add(.init(id: "verse:" + document.id.uuidString + ":" + verse.id.uuidString,
                              kind: .unresolvedLink, title: verse.reference, detail: document.title))
                }
            }
            if let edition = document.verseListEdition, !identities.contains(Identity(id: edition.resourceID, format: edition.format, legacy: edition.legacyIdentifier)) {
                add(.init(id: "edition:" + document.id.uuidString, kind: .unresolvedLink, title: document.title, detail: edition.title))
            }
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
        let legacyCounts = Dictionary(resources.compactMap { resource -> String? in
            guard [.legacyLSF, .libronixLLS].contains(resource.format) else { return nil }
            return LegacyNumericResourceID.fromBKIDHex(resource.legacyIdentifier)?.identifier ?? (resource.format == .libronixLLS ? resource.legacyIdentifier : nil)
        }.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        for collection in collections {
            if Task.isCancelled { break }
            for member in collection.members {
                if Task.isCancelled { break }
                if !identities.contains(Identity(id: member.resourceID, format: member.format, legacy: member.legacyIdentifier)) {
                    add(.init(id: "collection:" + collection.id.uuidString + ":" + member.id, kind: .unresolvedLink, title: member.title, detail: collection.name))
                }
            }
        }
        if !associations.isEmpty {
            let associationCatalog = ResourceAssociationCatalog(resources: resources)
            let byIdentity = Dictionary(resources.map { (Identity(id: $0.id, format: $0.format, legacy: $0.legacyIdentifier), $0) }, uniquingKeysWith: { first, _ in first })
            for association in associations {
                if Task.isCancelled { break }
                for member in association.members {
                    if Task.isCancelled { break }
                    let resolved: Bool
                    if association.original == nil {
                        let identity = Identity(id: member.resourceID, format: member.format, legacy: member.legacyIdentifier)
                        resolved = byIdentity[identity].map { association.supports($0, using: associationCatalog) } ?? false
                    } else { resolved = association.resolve(member, using: associationCatalog) != nil }
                    if !resolved {
                        add(.init(id: "association:" + association.id.uuidString + ":" + member.id, kind: .unresolvedLink, title: member.title, detail: association.name))
                    }
                }
            }
        }
        for plan in plans {
            if Task.isCancelled { break }
            if let edition = plan.edition, !identities.contains(Identity(id: edition.resourceID, format: edition.format, legacy: edition.legacyIdentifier)) {
                add(.init(id: "plan:" + plan.id.uuidString, kind: .unresolvedLink, title: plan.title, detail: edition.title))
            }
        }
        for card in memoryCards {
            if Task.isCancelled { break }
            if let edition = card.sourceEdition, !identities.contains(Identity(id: edition.resourceID, format: edition.format, legacy: edition.legacyIdentifier)) {
                add(.init(id: "memory:" + card.id.uuidString, kind: .unresolvedLink, title: card.reference, detail: edition.title))
            }
        }
        for excerpt in excerpts {
            if Task.isCancelled { break }
            let location = excerpt.location
            if !identities.contains(Identity(id: location.resourceID, format: location.format, legacy: location.legacyIdentifier)) {
                add(.init(id: "excerpt:" + excerpt.id.uuidString, kind: .unresolvedLink, title: excerpt.sourceTitle, detail: location.resourceID))
            }
        }
        for favorite in favorites {
            if Task.isCancelled { break }
            if let location = favorite.location, !identities.contains(Identity(id: location.resourceID, format: location.format, legacy: location.legacyIdentifier)) {
                add(.init(id: "favorite:" + favorite.id.uuidString, kind: .unresolvedLink, title: favorite.title, detail: location.resourceID))
            } else if let command = favorite.legacyCommand {
                let destination = try? LegacyJumpDestination.parse(command)
                if destination.map({ legacyCounts[$0.resourceID.lowercased()] != 1 }) ?? true {
                    add(.init(id: "favorite:" + favorite.id.uuidString, kind: .unresolvedLink, title: favorite.title, detail: command))
                }
            }
        }
        for (slot, location) in bookmarks.sorted(by: { $0.key < $1.key }) where !identities.contains(Identity(id: location.resourceID, format: location.format, legacy: location.legacyIdentifier)) {
            add(.init(id: "bookmark:" + String(slot), kind: .unresolvedLink, title: String(slot), detail: location.resourceID))
        }
        for mark in highlights where !resourceIDs.contains(mark.resourceID) {
            if Task.isCancelled { break }
            add(.init(id: "highlight:" + mark.id.uuidString, kind: .missingAnnotationSource,
                      title: mark.resourceID, detail: ""))
        }
        return .init(resourceCount: resources.count, issues: issues, omittedIssueCount: omitted)
    }
}
