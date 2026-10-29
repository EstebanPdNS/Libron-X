import AppKit
import UniformTypeIdentifiers
import LibronixCore

@MainActor enum ReaderOutputActions {
    static func document(_ reader: ReaderSession, selectionOnly: Bool = false) throws -> NSAttributedString {
        guard let page = reader.page else { throw ReaderOutputError.invalidSelection }
        guard page.oeb == nil else { throw PersonalStateError.invalid("Esta lectura conserva su formato mediante HTML, archivo web o PDF.") }
        if !selectionOnly && page.passageParts.count > 1 {
            let output = NSMutableAttributedString()
            for part in page.passageParts {
                let display = NSMutableAttributedString(attributedString: ReaderTypography.render(text: part.content.plainText,
                    content: part.content, typography: page.typography,
                    visibleInterlinearLines: page.interlinearLines.isEmpty ? nil : reader.effectiveInterlinearLines).text)
                _ = ReaderImageRenderer.install(part.graphics, in: display)
                let selected = selectedDocument(display, range: part.selection)
                appendPassagePart(selected, to: output)
            }
            return output
        }
        let display = NSMutableAttributedString(attributedString: ReaderTypography.render(text: page.text, content: page.content, typography: page.typography,
            visibleInterlinearLines: page.interlinearLines.isEmpty ? nil : reader.effectiveInterlinearLines).text)
        _ = ReaderImageRenderer.install(page.graphics, in: display)
        if selectionOnly {
            guard reader.selectedRange.length > 0, Range(reader.selectedRange, in: page.text) != nil else { throw ReaderOutputError.invalidSelection }
            return selectedDocument(display, range: reader.selectedRange)
        }
        return display
    }
    static func appendPassagePart(_ part: NSAttributedString, to output: NSMutableAttributedString) {
        if output.length > 0, !output.string.hasSuffix("\n"), !part.string.hasPrefix("\n") {
            output.append(NSAttributedString(string: "\n"))
        }
        let offset = output.length
        output.append(part)
        output.enumerateAttribute(.readerInterlinearUnit, in: NSRange(location: offset, length: part.length)) { value, span, _ in
            guard let unit = value as? ReaderInterlinearGlyph else { return }
            output.addAttribute(.readerInterlinearUnit, value: unit.rebased(to: span), range: span)
        }
    }
    static func selectedDocument(_ display: NSAttributedString, range: NSRange) -> NSAttributedString {
        let selected = NSMutableAttributedString(attributedString: display.attributedSubstring(from: range))
        selected.enumerateAttribute(.readerInterlinearUnit, in: NSRange(location: 0, length: selected.length)) { value, span, _ in
            guard let unit = value as? ReaderInterlinearGlyph else { return }
            if NSIntersectionRange(unit.sourceRange, range) == unit.sourceRange {
                selected.addAttribute(.readerInterlinearUnit, value: unit.rebased(to: span), range: span)
            } else {
                // A partial surface-word selection cannot claim the entire
                // annotation unit; preserve only the selected source text.
                selected.removeAttribute(.readerInterlinearUnit, range: span)
            }
        }
        return selected
    }
    static func copiesExplicitSelection(_ reader: ReaderSession) -> Bool {
        // A newly opened passage selects its current source part. Preserve the
        // complete passage for the default copy/export; a changed selection is
        // the user's explicit interval in the current physical article.
        reader.selectedRange.length > 0 && !(reader.page?.passageParts.count ?? 0 > 1 && reader.selectedRange == reader.page?.selection)
    }
    static func copy(_ reader: ReaderSession, workspace: StudyWorkspace) {
        if reader.page?.oeb != nil { ReaderOEBOutput.copy(reader, workspace: workspace); return }
        do {
            let text = try document(reader, selectionOnly: copiesExplicitSelection(reader))
            let range = NSRange(location: 0, length: text.length)
            let board = NSPasteboard.general; board.clearContents()
            board.setString(text.string, forType: .string)
            board.setData(try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
            if let html = try? text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) { board.setData(html, forType: .html) }
        } catch { workspace.error = error.localizedDescription }
    }
    static func export(_ reader: ReaderSession, type: String, workspace: StudyWorkspace) {
        let panel = NSSavePanel(); panel.title = L("Exportar lectura")
        let contentType: UTType = type == "webarchive" ? UTType(filenameExtension: "webarchive") ?? .data : type == "pdf" ? .pdf : type == "rtfd" ? .rtfd : type == "html" ? .html : .plainText
        panel.allowedContentTypes = [contentType]; panel.nameFieldStringValue = reader.resource.title + "." + type
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if reader.page?.oeb != nil {
                Task {
                    do { try await ReaderOEBOutput.write(reader, type: type, url: url) }
                    catch { workspace.error = error.localizedDescription }
                }
                return
            }
            do {
                let text = try document(reader, selectionOnly: copiesExplicitSelection(reader))
                try write(text, to: url, type: type)
            } catch { workspace.error = error.localizedDescription }
        }
    }
    static func write(_ text: NSAttributedString, to url: URL, type: String, printInfo: NSPrintInfo? = nil) throws {
        let range = NSRange(location: 0, length: text.length)
        switch type {
        case "txt": try Data(text.string.utf8).write(to: url, options: .atomic)
        case "html": try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]).write(to: url, options: .atomic)
        case "rtfd":
            let wrapper = try text.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        case "pdf":
            let info = (printInfo ?? NSPrintInfo.shared).copy() as! NSPrintInfo
            info.jobDisposition = .save; info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let operation = NSPrintOperation(view: printView(text, info: info), printInfo: info)
            operation.showsPrintPanel = false; operation.showsProgressPanel = false
            guard operation.run() else { throw PersonalStateError.invalid("No se pudo crear el PDF.") }
        default: throw PersonalStateError.invalid("El formato de exportación no está disponible.")
        }
    }
    static func printReader(_ reader: ReaderSession, workspace: StudyWorkspace) {
        if reader.page?.oeb != nil { ReaderOEBOutput.printReader(reader); return }
        do {
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            let operation = NSPrintOperation(view: printView(try document(reader), info: info), printInfo: info)
            operation.showsPrintPanel = true; operation.showsProgressPanel = true
            operation.run()
        } catch { workspace.error = error.localizedDescription }
    }
    static func printView(_ text: NSAttributedString, info: NSPrintInfo) -> NSTextView {
        let width = max(100, info.paperSize.width - info.leftMargin - info.rightMargin)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.textContainer?.replaceLayoutManager(ReaderLayoutManager())
        view.isEditable = false; view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.textContainerInset = NSSize(width: 0, height: 0)
        view.textContainer?.widthTracksTextView = true
        let display = NSMutableAttributedString(attributedString: text)
        display.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: display.length)) { value, range, _ in
            if (value as? NSColor) == NSColor.textColor { display.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        display.enumerateAttribute(.attachment, in: NSRange(location: 0, length: display.length)) { value, _, _ in
            guard let old = value as? NSTextAttachment else { return }
            let bounds = old.bounds
            if bounds.width > width { old.bounds.size = NSSize(width: width, height: bounds.height * width / bounds.width) }
        }
        view.textStorage?.setAttributedString(display)
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container); view.setFrameSize(NSSize(width: width, height: max(100, layout.usedRect(for: container).height)))
        }
        return view
    }
}
