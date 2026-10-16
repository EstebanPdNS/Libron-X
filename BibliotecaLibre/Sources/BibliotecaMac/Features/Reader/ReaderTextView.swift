import AppKit
import LibronixCore
import SwiftUI

struct ReaderGraphic: Equatable {
    let offset: Int
    let data: Data
    let sha256: String
}
struct ReaderAnnotation: Identifiable, Equatable {
    let documentID: UUID
    let noteID: UUID
    let title: String
    let range: SearchTextRange?
    var id: String { documentID.uuidString + ":" + noteID.uuidString }
}

final class AttachmentReaderTextView: NSTextView {
    var inlineImages: [(attachment: NSTextAttachment, range: NSRange, size: NSSize, columns: Int)] = []
    private var lastImageWidth = -1.0
    override func layout() {
        super.layout()
        resizeInlineImages()
    }
    func resizeInlineImages(force: Bool = false) {
        let available = max(1, bounds.width - 2 * textContainerInset.width)
        guard available > 1, force || abs(available - lastImageWidth) > 0.5 else { return }
        lastImageWidth = available
        for item in inlineImages {
            let cellWidth = item.columns > 1 ? max(1, available / CGFloat(item.columns) - 16) : available
            let scale = min(1, cellWidth / item.size.width)
            item.attachment.bounds = NSRect(x: 0, y: 0, width: item.size.width * scale, height: item.size.height * scale)
            layoutManager?.invalidateLayout(forCharacterRange: item.range, actualCharacterRange: nil)
        }
    }
}

/// The platform owns selection, scrolling and Copy. The string is decoder output.
struct ReaderTextView: NSViewRepresentable {
    let text: String
    let fontSize: Double
    let fontFamily: String
    let highlightRange: NSRange?
    var graphics: [ReaderGraphic] = []
    var tables: [LegacyTable] = []
    var annotations: [ReaderAnnotation] = []
    var selectionChanged: ((NSRange, String) -> Void)?
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text = ""
        var fontSize = 0.0
        var fontFamily = ""
        var range: NSRange?
        var graphics: [ReaderGraphic] = []
        var tables: [LegacyTable] = []
        var annotations: [ReaderAnnotation] = []
        var selectionChanged: ((NSRange, String) -> Void)?
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let reader = notification.object as? NSTextView else { return }
            let range = reader.selectedRange(), text = reader.string, callback = selectionChanged
            Task { @MainActor in callback?(range, text) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .textBackgroundColor
        let reader = AttachmentReaderTextView(frame: .zero)
        reader.isEditable = false
        reader.isSelectable = true
        reader.isVerticallyResizable = true
        reader.isHorizontallyResizable = false
        reader.autoresizingMask = [.width]
        reader.minSize = .zero
        reader.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        reader.textContainer?.widthTracksTextView = true
        reader.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        reader.textContainerInset = NSSize(width: 30, height: 30)
        reader.backgroundColor = .textBackgroundColor
        reader.setAccessibilityLabel("Texto del artículo")
        reader.delegate = context.coordinator
        scroll.documentView = reader
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let reader = scroll.documentView as? AttachmentReaderTextView else { return }
        let coordinator = context.coordinator
        coordinator.selectionChanged = selectionChanged
        let changed = coordinator.text != text
        if changed || coordinator.fontSize != fontSize || coordinator.fontFamily != fontFamily || coordinator.graphics != graphics || coordinator.tables != tables || coordinator.annotations != annotations {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 7
            paragraph.paragraphSpacing = 8
            paragraph.baseWritingDirection = .natural
            let size = min(32, max(12, fontSize))
            let font = fontFamily == "serif" ? NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            let selection = reader.selectedRange()
            let display = NSMutableAttributedString(string: text,
                attributes: [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph])
            // NSTextTable applies layout attributes to the existing string;
            // it does not insert tabs or alter decoded/search coordinates.
            for source in tables {
                let columns = max(1, Int(source.columnCount), source.rows.map { $0.cells.count }.max() ?? 0)
                let table = NSTextTable()
                table.numberOfColumns = columns
                table.layoutAlgorithm = .fixed
                table.collapsesBorders = true
                table.hidesEmptyCells = false
                table.setContentWidth(100, type: .percentage)
                for (rowIndex, row) in source.rows.enumerated() {
                    for (columnIndex, cell) in row.cells.enumerated() {
                        let range = NSRange(location: cell.characterOffset, length: cell.characterCount)
                        guard range.length > 0, range.location >= 0, NSMaxRange(range) <= display.length,
                              Range(range, in: text) != nil else { continue }
                        let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                            startingColumn: columnIndex, columnSpan: 1)
                        block.setContentWidth(100 / CGFloat(columns), type: .percentage)
                        block.setWidth(8, type: .absolute, for: .padding)
                        block.setWidth(0.5, type: .absolute, for: .border)
                        block.setBorderColor(NSColor.separatorColor)
                        block.verticalAlignment = .top
                        if rowIndex.isMultiple(of: 2) { block.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.3) }
                        let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                        style.lineSpacing = 3; style.paragraphSpacing = 4
                        style.textBlocks = [block]
                        display.addAttribute(.paragraphStyle, value: style, range: range)
                    }
                }
            }
            reader.inlineImages = []
            for graphic in graphics where graphic.offset >= 0 && graphic.offset < display.length {
                guard (text as NSString).character(at: graphic.offset) == 0xfffc,
                      let image = NSImage(data: graphic.data), image.size.width > 0, image.size.height > 0 else { continue }
                let attachment = NSTextAttachment()
                attachment.image = image
                let range = NSRange(location: graphic.offset, length: 1)
                attachment.bounds = NSRect(origin: .zero, size: image.size)
                display.addAttribute(.attachment, value: attachment, range: range)
                let table = tables.first { table in table.rows.contains { row in row.cells.contains { cell in
                    graphic.offset >= cell.characterOffset && graphic.offset < cell.characterOffset + cell.characterCount
                } } }
                let columns = table.map { max(1, Int($0.columnCount), $0.rows.map { $0.cells.count }.max() ?? 0) } ?? 1
                reader.inlineImages.append((attachment, range, image.size, columns))
            }
            reader.textStorage?.setAttributedString(display)
            let fullRange = NSRange(location: 0, length: display.length)
            reader.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
            for annotation in annotations {
                guard let range = annotation.range, range.location >= 0, range.length > 0,
                      range.location <= display.length, range.length <= display.length - range.location,
                      Range(range.nsRange, in: text) != nil else { continue }
                reader.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), forCharacterRange: range.nsRange)
            }
            reader.resizeInlineImages(force: true)
            coordinator.text = text; coordinator.fontSize = fontSize; coordinator.fontFamily = fontFamily
            coordinator.graphics = graphics
            coordinator.tables = tables
            coordinator.annotations = annotations
            if changed { reader.scrollRangeToVisible(NSRange(location: 0, length: 0)); coordinator.range = nil }
            else if NSMaxRange(selection) <= (text as NSString).length { reader.setSelectedRange(selection) }
        }
        if coordinator.range != highlightRange {
            coordinator.range = highlightRange
            if let range = highlightRange, range.location != NSNotFound, range.location >= 0,
               range.length >= 0, range.location <= (text as NSString).length,
               range.length <= (text as NSString).length - range.location {
                reader.setSelectedRange(range)
                reader.scrollRangeToVisible(range)
            }
        }
    }
}
