import AppKit
import SwiftUI
import Observation
import LibronixCore

@MainActor @Observable final class NoteEditorController: NSObject, NSTextViewDelegate {
    private(set) var noteID: UUID?
    private(set) var isBold = false
    private(set) var isItalic = false
    private(set) var isUnderlined = false
    private(set) var hasSelection = false
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var readOnly = false
    var error: String?
    @ObservationIgnored weak var editor: NSTextView?
    @ObservationIgnored private var loadedRTF: Data?
    @ObservationIgnored private var loadedBody = ""
    @ObservationIgnored private var loadedType = ""
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var changed: ((Data) -> Void)?

    func configure(_ note: StudyNote, editor: NSTextView, changed: @escaping (Data) -> Void) {
        self.editor = editor; self.changed = changed
        guard noteID != note.id || loadedRTF != note.editedRTF || loadedBody != note.sourceBody || loadedType != note.sourceContentType else { return }
        applying = true; defer { applying = false; refresh() }
        let differentNote = noteID != note.id, previousSelection = editor.selectedRange()
        noteID = note.id; loadedRTF = note.editedRTF; loadedBody = note.sourceBody; loadedType = note.sourceContentType
        do {
            editor.textStorage?.setAttributedString(try NoteRichTextCodec.attributed(note))
            readOnly = false; error = nil
        } catch {
            // Keep malformed saved edits intact. A read-only source projection
            // prevents the first keystroke from replacing recoverable bytes.
            editor.textStorage?.setAttributedString(NoteRichTextCodec.source(note))
            readOnly = true; self.error = error.localizedDescription
        }
        editor.isEditable = !readOnly
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.textColor]
        editor.undoManager?.removeAllActions()
        let range = !differentNote && NSMaxRange(previousSelection) <= editor.string.utf16.count ? previousSelection : NSRange(location: 0, length: 0)
        editor.setSelectedRange(range)
    }

    func textDidChange(_ notification: Notification) {
        guard !applying, !readOnly, let editor, let storage = editor.textStorage else { return }
        do {
            let data = try NoteRichTextCodec.encode(storage)
            loadedRTF = data; changed?(data); error = nil
        } catch { self.error = error.localizedDescription }
        refresh()
    }

    func textViewDidChangeSelection(_ notification: Notification) { refresh() }

    func refresh() {
        guard let editor else { return }
        let range = editor.selectedRange()
        hasSelection = range.length > 0
        let attributes = range.length > 0 && range.location < editor.string.utf16.count
            ? editor.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? editor.typingAttributes
            : editor.typingAttributes
        let traits = NSFontManager.shared.traits(of: attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 16))
        isBold = traits.contains(.boldFontMask); isItalic = traits.contains(.italicFontMask)
        isUnderlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
        canUndo = editor.undoManager?.canUndo ?? false; canRedo = editor.undoManager?.canRedo ?? false
    }

    func toggleFont(_ trait: NSFontTraitMask) {
        guard let editor, !readOnly else { return }
        let enabled = trait == .boldFontMask ? !isBold : !isItalic
        func convert(_ font: NSFont) -> NSFont {
            enabled ? NSFontManager.shared.convert(font, toHaveTrait: trait) : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
        }
        let range = editor.selectedRange()
        if range.length == 0 {
            var attributes = editor.typingAttributes
            attributes[.font] = convert(attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 16))
            editor.typingAttributes = attributes; focus(); refresh(); return
        }
        mutateSelection(name: trait == .boldFontMask ? "Negrita" : "Cursiva") { text in
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                text.addAttribute(.font, value: convert(value as? NSFont ?? NSFont.systemFont(ofSize: 16)), range: range)
            }
        }
    }

    func toggleUnderline() {
        guard let editor, !readOnly else { return }
        let enabled = !isUnderlined
        if editor.selectedRange().length == 0 {
            editor.typingAttributes[.underlineStyle] = enabled ? NSUnderlineStyle.single.rawValue : 0
            focus(); refresh(); return
        }
        mutateSelection(name: "Subrayado") { text in
            text.addAttribute(.underlineStyle, value: enabled ? NSUnderlineStyle.single.rawValue : 0, range: NSRange(location: 0, length: text.length))
        }
    }

    func validLink(_ target: String) -> Bool {
        NoteRichTextCodec.webURL(target) != nil || (try? BibleReferenceQuery.parse(target)) != nil
    }

    func setLink(_ target: String?) {
        let target = target?.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = target.flatMap { NoteRichTextCodec.webURL($0) ?? ((try? BibleReferenceQuery.parse($0)) != nil ? NoteRichTextCodec.referenceURL($0) : nil) }
        guard target == nil || link != nil else { return }
        mutateSelection(name: target == nil ? "Quitar enlace" : "Insertar enlace") { text in
            let range = NSRange(location: 0, length: text.length)
            if let link { text.addAttribute(.link, value: link, range: range) }
            else { text.removeAttribute(.link, range: range) }
        }
    }

    /// List markers are visible text, including after RTF export. Replacing
    /// complete paragraphs preserves every existing inline attribute and link.
    func list(numbered: Bool) {
        guard let editor, let storage = editor.textStorage, !readOnly else { return }
        let paragraphRange = (editor.string as NSString).paragraphRange(for: editor.selectedRange())
        let original = storage.attributedSubstring(from: paragraphRange)
        let replacement = NSMutableAttributedString(string: "")
        let plain = original.string as NSString
        var location = 0, number = 1
        repeat {
            let range = plain.paragraphRange(for: NSRange(location: location, length: 0))
            let attributes = original.length > range.location ? original.attributes(at: range.location, effectiveRange: nil) : editor.typingAttributes
            replacement.append(NSAttributedString(string: numbered ? "\(number). " : "• ", attributes: attributes))
            replacement.append(original.attributedSubstring(from: range))
            number += 1; location = NSMaxRange(range)
        } while location < plain.length
        replace(paragraphRange, with: replacement, name: numbered ? "Lista numerada" : "Lista con viñetas")
    }

    private func mutateSelection(name: String, transform: (NSMutableAttributedString) -> Void) {
        guard let editor, let storage = editor.textStorage, !readOnly else { return }
        let range = editor.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let value = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        transform(value); replace(range, with: value, name: name)
    }

    private func replace(_ range: NSRange, with value: NSAttributedString, name: String) {
        guard let editor, let storage = editor.textStorage, !readOnly, let identity = noteID,
              range.location >= 0, range.length >= 0, range.location <= storage.length,
              range.length <= storage.length - range.location else { return }
        let original = storage.attributedSubstring(from: range), manager = editor.undoManager
        editor.breakUndoCoalescing()
        manager?.disableUndoRegistration()
        guard editor.shouldChangeText(in: range, replacementString: value.string) else { manager?.enableUndoRegistration(); return }
        storage.replaceCharacters(in: range, with: value)
        editor.didChangeText(); manager?.enableUndoRegistration()
        manager?.registerUndo(withTarget: self) { controller in
            guard controller.noteID == identity else { return }
            controller.replace(NSRange(location: range.location, length: value.length), with: original, name: name)
        }
        manager?.setActionName(L(name))
        editor.setSelectedRange(NSRange(location: range.location, length: value.length)); focus(); refresh()
    }

    func undo() { focus(); editor?.undoManager?.undo(); refresh() }
    func redo() { focus(); editor?.undoManager?.redo(); refresh() }
    private func focus() { if let editor { editor.window?.makeFirstResponder(editor) } }
}

private struct NativeNoteTextView: NSViewRepresentable {
    let note: StudyNote
    let controller: NoteEditorController
    let changed: (Data) -> Void
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = NSTextView(frame: .zero)
        editor.isRichText = true; editor.importsGraphics = false; editor.allowsUndo = true
        editor.isSelectable = true; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(L("Contenido de la nota")); editor.setAccessibilityIdentifier("notes.richEditor")
        editor.delegate = controller; scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.setAccessibilityLabel(L("Contenido de la nota"))
        controller.configure(note, editor: editor, changed: changed)
    }
}

struct WorkspaceNoteEditor: View {
    let note: StudyNote
    let changed: (Data) -> Void
    @RebuildViewState private var controller = NoteEditorController()
    @RebuildViewState private var showsLink = false
    @RebuildViewState private var link = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacReaderToolbarSurface {
                HStack(spacing: 8) {
                    MacReaderControlGroup {
                        Toggle(isOn: Binding(get: { controller.isBold }, set: { _ in controller.toggleFont(.boldFontMask) })) { MacToolbarLabel("Negrita", "bold") }.help(L("Negrita")).keyboardShortcut("b")
                        Toggle(isOn: Binding(get: { controller.isItalic }, set: { _ in controller.toggleFont(.italicFontMask) })) { MacToolbarLabel("Cursiva", "italic") }.help(L("Cursiva")).keyboardShortcut("i")
                        Toggle(isOn: Binding(get: { controller.isUnderlined }, set: { _ in controller.toggleUnderline() })) { MacToolbarLabel("Subrayado", "underline") }.help(L("Subrayado")).keyboardShortcut("u")
                    }.toggleStyle(.button)
                    MacReaderControlGroup {
                        Menu {
                            Button(L("Lista con viñetas")) { controller.list(numbered: false) }
                            Button(L("Lista numerada")) { controller.list(numbered: true) }
                        } label: { MacToolbarMenuLabel("Listas", "list.bullet") }.help(L("Listas"))
                        Menu {
                            Button(L("Insertar enlace")) { link = ""; showsLink = true }
                            Button(L("Quitar enlace")) { controller.setLink(nil) }
                        } label: { MacToolbarMenuLabel("Enlaces", "link") }.disabled(!controller.hasSelection).help(L("Enlaces"))
                    }
                    Spacer(minLength: 0)
                    MacReaderControlGroup {
                        MacToolbarButton("Deshacer", "arrow.uturn.backward") { controller.undo() }.disabled(!controller.canUndo)
                        MacToolbarButton("Rehacer", "arrow.uturn.forward") { controller.redo() }.disabled(!controller.canRedo)
                    }
                }.disabled(controller.readOnly)
            }
            if NoteRichTextCodec.hasUnsupportedHTMLObjects(note) {
                Text(L("El HTML original se conserva; los objetos no compatibles no se editan.")).font(.caption).foregroundStyle(.secondary)
            }
            if let error = controller.error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            NativeNoteTextView(note: note, controller: controller, changed: changed)
        }
        .onChange(of: note.id) { showsLink = false }
        .sheet(isPresented: $showsLink) {
            VStack(alignment: .leading, spacing: 14) {
                MacToolHeader(title: "Insertar enlace") { showsLink = false }
                TextField(L("Dirección web o referencia bíblica"), text: $link).macInputStyle().onSubmit(applyLink)
                HStack { Spacer(); Button(L("Aplicar"), action: applyLink).disabled(!controller.validLink(link.trimmingCharacters(in: .whitespacesAndNewlines))) }
            }.padding(20).frame(width: 440).modifier(MacPanelControlPresentation()).modifier(AppInterfaceLanguage())
        }
    }
    private func applyLink() {
        let target = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard controller.validLink(target) else { return }
        controller.setLink(target); showsLink = false
    }
}
