import Foundation

public struct ImportFormattingAudit: Codable, Sendable {
    public var pipelineVersion = ImportFormattingPipeline.version
    public var entries = 0
    public var htmlEntries = 0
    public var rtfEntries = 0
    public var plainEntries = 0
    public var emptyEntries = 0
    public var activeSurfacesRemoved = 0
    public var legacyCharacterRepairs = 0
    public var tables = 0
    public var lists = 0
    public var issues: [String] = []
    public init() {}
    public mutating func record(_ source: String, ordinal: Int) {
        entries += 1
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emptyEntries += 1; if issues.count < 32 { issues.append("Empty source entry: \(ordinal)") }; return }
        if source.hasPrefix("{\\rtf") { rtfEntries += 1; return }
        if source.contains("<") {
            htmlEntries += 1
            let normalized = ImportFormattingPipeline.html(source)
            activeSurfacesRemoved += normalized.removedActiveSurfaces
            tables += source.components(separatedBy: "<table").count - 1
            lists += source.components(separatedBy: "<ul").count + source.components(separatedBy: "<ol").count - 2
            var visible = source.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
            let entities = ["&sigma;":"σ","&alpha;":"α","&#x05D1;":"ב","&#x05DD;":"ם","&#x05EA;":"ת","&#x05E3;":"ף","&#xF88E;":"\u{F88E}"]
            for (entity, character) in entities { visible = visible.replacingOccurrences(of: entity, with: character, options: .caseInsensitive) }
            legacyCharacterRepairs += ImportFormattingPipeline.repairLegacyCharacters(visible).repairedCharacters
        } else { plainEntries += 1; legacyCharacterRepairs += ImportFormattingPipeline.repairLegacyCharacters(source).repairedCharacters }
    }
}
