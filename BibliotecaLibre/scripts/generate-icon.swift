import AppKit
import Foundation

// Builds consume the reviewed vector-derived artwork by Esteban. Re-tracing
// belongs to vectorize-brand.py, not a normal app build. No artwork license is
// implied by the license of this script or the vectorization tools.
enum BrandAssetError: Error { case missingArgument, invalidPNG(String) }
guard CommandLine.arguments.count == 2 else { throw BrandAssetError.missingArgument }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let approved = directory.appendingPathComponent("Brand")
let iconset = directory.appendingPathComponent("LibronX.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func copyValidatedPNG(from source: URL, to destination: URL, expectedSize: Int) throws {
    let data = try Data(contentsOf: source)
    guard let image = NSBitmapImageRep(data: data), image.pixelsWide == expectedSize,
          image.pixelsHigh == expectedSize, image.hasAlpha else {
        throw BrandAssetError.invalidPNG(source.lastPathComponent)
    }
    try data.write(to: destination, options: .atomic)
}

for logical in [16, 32, 128, 256, 512] {
    for multiple in [1, 2] {
        let suffix = multiple == 2 ? "@2x" : ""
        let name = "icon_\(logical)x\(logical)\(suffix).png"
        try copyValidatedPNG(from: approved.appendingPathComponent("iconset/LibronX.iconset/\(name)"),
            to: iconset.appendingPathComponent(name), expectedSize: logical * multiple)
    }
}
try copyValidatedPNG(from: approved.appendingPathComponent("raster/Libron-X-app-icon-1024.png"),
    to: directory.appendingPathComponent("LibronX-1024.png"), expectedSize: 1024)
