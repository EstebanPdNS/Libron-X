import Foundation

/// A local resource identity and checked UTF-16 position, not a versification
/// translation. A moved resource can be unavailable even if an edition exists.
public enum ReaderLocationLink {
    private struct Envelope: Codable { let version: Int; let location: ReaderLocation }
    public static func make(_ location: ReaderLocation) throws -> URL {
        try validate(location)
        let data = try JSONEncoder().encode(Envelope(version: 1, location: location))
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard let url = URL(string: "libronx://location/v1/" + encoded) else { throw Error.invalid }
        return url
    }
    public static func parse(_ url: URL) throws -> ReaderLocation {
        guard url.absoluteString.utf8.count <= 32_768,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "libronx", parts.host?.lowercased() == "location",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.hasPrefix("/v1/") else { throw Error.invalid }
        let encoded = String(parts.percentEncodedPath.dropFirst(4))
        guard !encoded.isEmpty, encoded.utf8.count <= 30_000,
              encoded.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw Error.invalid }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.count <= 20_000,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1 else { throw Error.invalid }
        try validate(envelope.location); return envelope.location
    }
    private static func validate(_ location: ReaderLocation) throws {
        guard !location.resourceID.isEmpty, location.resourceID.utf8.count <= 4096, !location.resourceID.contains("\0"),
              (location.legacyIdentifier?.utf8.count ?? 0) <= 1024, !(location.legacyIdentifier?.contains("\0") ?? false),
              (location.reference?.utf8.count ?? 0) <= 1024, !(location.reference?.contains("\0") ?? false),
              location.sectionOrdinal >= 0, let offset = location.characterOffset, offset >= 0,
              let fingerprint = location.textFingerprint, fingerprint.count == 64,
              fingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw Error.invalid }
    }
    public enum Error: Swift.Error, LocalizedError {
        case invalid
        public var errorDescription: String? { "El enlace de ubicación no es válido o no es compatible." }
    }
}
