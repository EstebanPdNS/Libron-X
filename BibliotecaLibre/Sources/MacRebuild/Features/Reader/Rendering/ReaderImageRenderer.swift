import AppKit
import ImageIO
import LibronixCore

@MainActor enum ReaderImageRenderer {
    struct Result {
        var images: [ActiveTextView.InlineImage] = []
        var warnings: [String] = []
    }
    static func install(_ assets: [LegacyGraphicAsset], in display: NSMutableAttributedString) -> Result {
        var result = Result()
        for asset in assets {
            let position = asset.graphic.objectCharacterOffset
            guard position >= 0, position < display.length, (display.string as NSString).character(at: position) == 0xfffc else {
                result.warnings.append("La imagen \(asset.name) no coincide con su posición en el artículo."); continue
            }
            guard let image = decode(asset.data) else {
                result.warnings.append("No se pudo decodificar la imagen \(asset.name)."); continue
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.fileWrapper = FileWrapper(regularFileWithContents: asset.data)
            attachment.fileWrapper?.preferredFilename = asset.name
            attachment.bounds = NSRect(origin: .zero, size: image.size)
            let range = NSRange(location: position, length: 1)
            display.addAttribute(.attachment, value: attachment, range: range)
            display.addAttribute(.toolTip, value: "\(asset.name) · Doble clic para ampliar", range: range)
            result.images.append(.init(attachment: attachment, range: range, image: image, originalSize: image.size, name: asset.name))
        }
        return result
    }
    static func decode(_ data: Data) -> NSImage? {
        // Bound raster allocation before AppKit requests the complete image.
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            let w = width.doubleValue, h = height.doubleValue
            guard w > 0, h > 0, w * h <= 64_000_000 else { return nil }
        }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }
}
