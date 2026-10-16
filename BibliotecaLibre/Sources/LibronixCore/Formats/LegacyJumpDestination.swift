import Foundation

/// Read the measured jump data without invoking an original command handler.
/// The original reference stays typed as source data until its datatype and
/// versification can be translated. The checked article position owns the jump.
public struct LegacyJumpDestination: Sendable, Equatable {
    public let resourceID: String
    public let position: String
    public let originalReference: String?

    public static func parse(_ source: String) throws -> LegacyJumpDestination {
        guard source.utf16.count <= 4_096 else { throw LegacyLocatorError.invalidSyntax }
        let fields = source.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.first == "jump" else { throw LegacyLocatorError.invalidSyntax }
        var values: [String: String] = [:]
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, ["pos", "res", "ref"].contains(String(pair[0])),
                  values[String(pair[0])] == nil, !pair[1].isEmpty else { throw LegacyLocatorError.invalidSyntax }
            values[String(pair[0])] = String(pair[1])
        }
        guard let position = values["pos"], let resource = values["res"], resource.hasPrefix("LLS:"),
              resource.utf16.count <= 260, !resource.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LegacyLocatorError.invalidSyntax
        }
        _ = try LegacyArticleLocator.parse(position)
        return .init(resourceID: resource, position: position, originalReference: values["ref"])
    }
}
