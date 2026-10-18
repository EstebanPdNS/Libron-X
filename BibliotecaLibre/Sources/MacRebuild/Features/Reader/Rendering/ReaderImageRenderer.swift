import AppKit
import ImageIO
import LibronixCore

@MainActor enum ReaderImageRenderer {
    struct Result {
        var images: [ActiveTextView.InlineImage] = []
        var warnings: [String] = []
    }
    nonisolated static func isDecoration(_ asset: LegacyGraphicAsset) -> Bool {
        let name = URL(fileURLWithPath: asset.name).lastPathComponent.lowercased()
        return ["hcp-rule.jpg", "sbbt_icon.png", "sbmap_icon.png", "sba_icon.png"].contains(name)
    }
    static func install(_ assets: [LegacyGraphicAsset], in display: NSMutableAttributedString, detached: Bool = false) -> Result {
        var result = Result()
        for asset in assets {
            let position = asset.graphic.objectCharacterOffset
            guard position >= 0, position < display.length, (display.string as NSString).character(at: position) == 0xfffc else {
                result.warnings.append("La imagen \(asset.name) no coincide con su posición en el artículo."); continue
            }
            if detached || isDecoration(asset) {
                // Keep every original UTF-16 coordinate. Only the presentation
                // replaces this one object with an invisible, one-unit spacer.
                let range = NSRange(location: position, length: 1)
                display.removeAttribute(.attachment, range: range)
                display.replaceCharacters(in: range, with: "\u{200b}")
                display.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: range)
                continue
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
