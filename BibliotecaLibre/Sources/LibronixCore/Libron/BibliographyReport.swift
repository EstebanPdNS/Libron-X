import Foundation

public enum BibliographyField: String, CaseIterable, Codable, Sendable {
    case title, originalTitle, subtitle, authors, contributors, year, originalYear, publisher, edition, series, languages, abbreviation
}
public enum BibliographyCertainty: String, Codable, Sendable {
    case declared, inferred, unverified, unknown
}
public struct BibliographyFieldRecord: Codable, Equatable, Sendable {
    public let field: BibliographyField
    public let values: [String]
    public let certainty: BibliographyCertainty
    public let pending: Bool
    public let evidence: [LibronEvidence]
    public var text: String { values.joined(separator:"; ") }
}
public struct BibliographyEntry: Codable, Equatable, Identifiable, Sendable {
    public let resourceID: String
    public let fileName: String
    public let format: ResourceFormat
    public let legacyIdentifier: String?
    public let fields: [BibliographyFieldRecord]
    public var id: String { resourceID }
    public func field(_ field: BibliographyField) -> BibliographyFieldRecord { fields.first { $0.field == field } ?? .init(field:field,values:[],certainty:.unknown,pending:true,evidence:[]) }
}
public enum BibliographyOrder: String, CaseIterable, Codable, Sendable {
    case authorTitle, title, yearTitle
}
public struct BibliographyScope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case library, collections, selection }
    public let kind: Kind
    public let names: [String]
    public let identities: [String]
    public let requestedCount: Int
    public let issues: [BibliographyScopeIssue]
    public init(kind:Kind,names:[String],requestedCount:Int,issues:[BibliographyScopeIssue] = [],identities:[String] = []) {
        self.kind=kind;self.names=names;self.identities=identities;self.requestedCount=requestedCount;self.issues=issues
    }
}
public struct BibliographyScopeIssue: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case missingCollection, missingResource, changedIdentity }
    public let identity: String
    public let title: String
    public let reason: Reason
    public init(identity:String,title:String,reason:Reason) { self.identity=identity;self.title=title;self.reason=reason }
}
public struct BibliographyReport: Codable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let generatedAt: Date
    public let scope: BibliographyScope
    public let sourceFingerprint: String
    public var entries: [BibliographyEntry]
    public var order: BibliographyOrder
    public var coverageComplete: Bool { scope.issues.isEmpty && scope.requestedCount == entries.count }
    public var unknownFieldCount: Int { entries.reduce(0) { $0 + $1.fields.filter { $0.certainty == .unknown }.count } }
    public var inferredFieldCount: Int { entries.reduce(0) { $0 + $1.fields.filter { $0.certainty == .inferred }.count } }
    public func ordered(by order:BibliographyOrder) -> Self {
        var value=self;value.order=order
        let locale=Locale(identifier:"en_US_POSIX")
        func compare(_ a:String,_ b:String) -> ComparisonResult {
            if a.isEmpty != b.isEmpty { return a.isEmpty ? .orderedDescending : .orderedAscending }
            return a.compare(b,options:[.caseInsensitive,.diacriticInsensitive,.numeric],locale:locale)
        }
        value.entries.sort { a,b in
            let first:BibliographyField = order == .authorTitle ? .authors : order == .yearTitle ? .year : .title
            let primary=compare(a.field(first).text,b.field(first).text)
            if primary != .orderedSame { return primary == .orderedAscending }
            let title=compare(a.field(.title).text,b.field(.title).text)
            return title == .orderedSame ? a.id < b.id : title == .orderedAscending
        }
        return value
    }
}
public enum BibliographyReportError: Error, Equatable, Sendable {
    case tooManyResources, duplicateIdentity, unsafeMetadata, invalidScope
}
public enum BibliographyReportGenerator {
    public static let maximumResources=100_000
    public static func generate(resources:[LibraryResource],scope:BibliographyScope,order:BibliographyOrder = .authorTitle,
                                generatedAt:Date = Date()) throws -> BibliographyReport {
        try Task.checkCancellation()
        guard resources.count <= maximumResources else { throw BibliographyReportError.tooManyResources }
        guard generatedAt.timeIntervalSince1970.isFinite,scope.requestedCount >= resources.count, scope.requestedCount <= maximumResources,
              scope.names.count <= 256, scope.identities.count <= maximumResources, scope.issues.count <= maximumResources else { throw BibliographyReportError.invalidScope }
        guard Set(resources.map(\.id)).count == resources.count else { throw BibliographyReportError.duplicateIdentity }
        var total=0,entries:[BibliographyEntry]=[]
        func check(_ text:String) throws {
            guard text.utf16.count <= 64_000,!text.contains("\0") else { throw BibliographyReportError.unsafeMetadata }
            total += text.utf16.count;guard total <= 16_000_000 else { throw BibliographyReportError.unsafeMetadata }
        }
        for name in scope.names { try check(name) }
        for id in scope.identities { try check(id) }
        for issue in scope.issues { try check(issue.identity);try check(issue.title) }
        for resource in resources {
            try Task.checkCancellation()
            guard !resource.id.isEmpty,resource.id.utf8.count <= 16_384 else { throw BibliographyReportError.duplicateIdentity }
            try check(resource.id);try check(resource.fileName)
            if let id=resource.legacyIdentifier { try check(id) }
            // The catalog is the input snapshot. Never infer or fetch missing edition data.
            let metadata=LibronMetadata.deriving(resource)
            let values:[BibliographyField:[String]]=[.title:[metadata.title],.originalTitle:metadata.originalTitle.map { [$0] } ?? [],.subtitle:metadata.subtitle.map { [$0] } ?? [],
                .authors:metadata.authors,.contributors:metadata.contributors,.year:metadata.year.map { [$0] } ?? [],
                .originalYear:metadata.originalYear.map { [$0] } ?? [],.publisher:metadata.publisher.map { [$0] } ?? [],
                .edition:metadata.edition.map { [$0] } ?? [],.series:metadata.collection.map { [$0] } ?? [],
                .languages:metadata.languages,.abbreviation:metadata.abbreviation.map { [$0] } ?? []]
            var fields:[BibliographyFieldRecord]=[]
            for field in BibliographyField.allCases {
                let actual=(values[field] ?? []).filter { !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
                guard actual.count <= 256,metadata.evidence.count <= 512 else { throw BibliographyReportError.unsafeMetadata }
                for text in actual { try check(text) }
                let aliases:Set<String>
                switch field {
                case .authors:aliases=["authors","author","dc.creator","creator"]
                case .contributors:aliases=["contributors","contributor"]
                case .languages:aliases=["languages","language"]
                case .series:aliases=["series","collection"]
                default:aliases=[field.rawValue]
                }
                let evidence=metadata.evidence.filter { aliases.contains($0.field) && (actual.contains($0.value) || $0.value == actual.joined(separator:"; ")) }
                for item in evidence { try check(item.field);try check(item.value);try check(item.source);try check(item.status) }
                let pending=metadata.pendingFields.contains { aliases.contains($0) }
                let certainty:BibliographyCertainty
                if actual.isEmpty { certainty = .unknown }
                else if evidence.contains(where: { $0.status.lowercased() == "inferred" }) { certainty = .inferred }
                else if pending || (field == .title && resource.provenance == .fileName) { certainty = .unverified }
                else if !evidence.isEmpty && actual.allSatisfy({ value in evidence.contains { $0.status.lowercased() == "verified" && ($0.value == value || $0.value == actual.joined(separator:"; ")) } }) { certainty = .declared }
                else { certainty = .unverified }
                fields.append(.init(field:field,values:actual,certainty:certainty,pending:pending,evidence:evidence))
            }
            entries.append(.init(resourceID:resource.id,fileName:resource.fileName,format:resource.format,legacyIdentifier:resource.legacyIdentifier,fields:fields))
        }
        try Task.checkCancellation()
        struct Witness:Encodable { let scope:BibliographyScope;let entries:[BibliographyEntry] }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(Witness(scope:scope,entries:entries.sorted { $0.id < $1.id }))
        let fingerprint=LibrarySearchService.textFingerprint(String(decoding:data,as:UTF8.self))
        return BibliographyReport(schemaVersion:1,id:UUID(),generatedAt:generatedAt,scope:scope,sourceFingerprint:fingerprint,entries:entries,order:order).ordered(by:order)
    }
}
