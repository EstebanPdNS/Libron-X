import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct LegacyGraphicSourceStamp: Sendable, Equatable {
    public let size: UInt64
    public let modified: Date
    public let fileNumber: UInt64?
}
public struct LegacyGraphicAsset: Sendable {
    public let graphic: LegacyGraphicRun
    public let name: String
    public let data: Data
    public let sha256: String
}
public struct LegacyGraphicsResult: Sendable {
    public let assets: [LegacyGraphicAsset]
    public let warnings: [String]
}

/// A single stamp-keyed directory cache; image bytes live only in the returned
/// article. This actor never writes library files or resolves external paths.
public actor LegacyGraphicsService {
    private var cache: (url: URL, stamp: LegacyGraphicSourceStamp, catalog: LegacyBagCatalog)?
    public init() {}

    public static func fileStamp(_ url: URL) throws -> LegacyGraphicSourceStamp {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date else {
            throw LegacyIndicesError.sourceChanged
        }
        return .init(size: size.uint64Value, modified: modified, fileNumber: (values[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    public func load(_ url: URL, graphics: [LegacyGraphicRun], expectedSource: LegacyGraphicSourceStamp,
                     maximumTotalBytes: Int = 64 * 1_024 * 1_024) throws -> LegacyGraphicsResult {
        try Task.checkCancellation()
        guard maximumTotalBytes > 0, maximumTotalBytes <= 128 * 1_024 * 1_024 else { throw LegacyBagError.assetLimit }
        guard try Self.fileStamp(url) == expectedSource else { throw LegacyIndicesError.sourceChanged }
        guard !graphics.isEmpty else { return .init(assets: [], warnings: []) }
        let catalog: LegacyBagCatalog
        do {
            if let cache, cache.url == url, cache.stamp == expectedSource { catalog = cache.catalog }
            else {
                catalog = try LegacyBagReader.inspect(url)
                cache = (url, expectedSource, catalog)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard try Self.fileStamp(url) == expectedSource else { throw LegacyIndicesError.sourceChanged }
            return .init(assets: [], warnings: ["Las imágenes del artículo no pudieron abrirse: \(error.localizedDescription)"])
        }
        var loaded: [String: (Data, String)] = [:], assets: [LegacyGraphicAsset] = [], warnings: [String] = []
        var total = 0
        for graphic in graphics {
            try Task.checkCancellation()
            guard let name = graphic.assetName else {
                warnings.append("La referencia gráfica en la posición \(graphic.objectCharacterOffset) no pertenece al subconjunto de imágenes internas compatible.")
                continue
            }
            do {
                let key = name.lowercased()
                let image: (Data, String)
                if let known = loaded[key] { image = known }
                else {
                    let data = try LegacyBagReader.read(url, catalog: catalog, name: name,
                                                      maximumBytes: min(LegacyBagReader.maximumAssetBytes, maximumTotalBytes - total))
                    guard data.count <= maximumTotalBytes - total else { throw LegacyBagError.assetLimit }
                    image = (data, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
                    loaded[key] = image; total += data.count
                }
                assets.append(.init(graphic: graphic, name: name, data: image.0, sha256: image.1))
                if graphic.reference.hasPrefix("[") {
                    warnings.append("La imagen \(name) conserva sus opciones originales; la escala y zonas activas todavía necesitan verificación.")
                }
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append("Imagen \(name): \(error.localizedDescription)") }
        }
        guard try Self.fileStamp(url) == expectedSource else { throw LegacyIndicesError.sourceChanged }
        return .init(assets: assets, warnings: warnings)
    }
}
