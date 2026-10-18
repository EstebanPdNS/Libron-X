import Foundation

public struct LibraryEditionGroup: Identifiable, Sendable {
    public enum Kind: String, Sendable { case exactCopies, differentReaders, possibleEditions }
    public let id: String
    public let kind: Kind
    public let resources: [LibraryResource]
}
public struct LibraryEditionAudit: Sendable {
    public let groups: [LibraryEditionGroup]
    public let issues: [String]
    public let examined: Int
    public let resources: [LibraryResource]
    public static func scan(_ resources: [LibraryResource]) throws -> Self {
        guard resources.count <= 100_000, Set(resources.map(\.id)).count == resources.count else { throw BibliographyReportError.duplicateIdentity }
        var exact: [String: [LibraryResource]] = [:], sources: [String: [LibraryResource]] = [:], works: [String: [LibraryResource]] = [:], issues: [String] = []
        func normalized(_ text: String) -> String {
            text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        }
        for resource in resources {
            try Task.checkCancellation()
            do {
                let source: String, reader: String
                if let package = resource.packageLocation {
                    let manifest = try LibronPackage.read(package, verify: true).0
                    guard manifest.id == resource.id else { throw LibronError.invalid("Changed resource identity") }
                    source = resource.format.rawValue + "|" + manifest.payload.sha256 + "|" + (manifest.index?.sha256 ?? "")
                    reader = manifest.normalizedContent?.sha256 ?? ""
                } else {
                    source = resource.format.rawValue + "|" + (try LibronPackage.hash(resource.location)) + "|" + (try resource.indexLocation.map(LibronPackage.hash) ?? "")
                    reader = ""
                }
                exact[source + "|" + reader, default: []].append(resource)
                sources[source, default: []].append(resource)
                let metadata = LibronMetadata.deriving(resource)
                let work = normalized(metadata.originalTitle ?? metadata.title) + "|" + metadata.authors.map(normalized).joined(separator: ";") + "|" + metadata.languages.sorted().joined(separator: ";")
                works[work, default: []].append(resource)
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append(resource.title + ": " + error.localizedDescription) }
        }
        var groups: [LibraryEditionGroup] = [], covered: Set<Set<String>> = []
        func append(_ buckets: [String: [LibraryResource]], kind: LibraryEditionGroup.Kind) {
            for key in buckets.keys.sorted() {
                let members = buckets[key]!.sorted { $0.id < $1.id }, ids = Set(members.map(\.id))
                guard members.count > 1, !covered.contains(ids) else { continue }
                covered.insert(ids)
                groups.append(.init(id: kind.rawValue + "|" + key, kind: kind, resources: members))
            }
        }
        append(exact, kind: .exactCopies); append(sources, kind: .differentReaders); append(works, kind: .possibleEditions)
        return .init(groups: groups, issues: issues, examined: resources.count - issues.count, resources: resources)
    }
}
