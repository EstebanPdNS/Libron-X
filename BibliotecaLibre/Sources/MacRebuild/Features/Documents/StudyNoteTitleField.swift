import AppKit
import SwiftUI
import LibronixCore

/// A title search never selects offsets in changed text or a different note.
enum StudyNoteTitleSearchTarget {
    static func range(_ destination: BibleReferencePersonalDestination?, noteID: UUID, title: String) -> Range<String.Index>? {
        guard let destination, destination.field == .noteTitle, destination.entryID == noteID,
              LibrarySearchService.textFingerprint(title) == destination.textSHA256,
              destination.range.location >= 0, destination.range.length > 0,
              destination.range.location <= title.utf16.count,
              destination.range.length <= title.utf16.count - destination.range.location else { return nil }
        return Range(destination.range.nsRange, in: title)
    }
    @MainActor static func apply(_ destination: BibleReferencePersonalDestination?, noteID: UUID, title: String, editor: NSTextView) -> Bool {
        guard editor.isFieldEditor, editor.string == title,
              range(destination, noteID: noteID, title: title) != nil, let destination else { return false }
        editor.setSelectedRange(destination.range.nsRange)
        return true
    }
}

/// Keep the system text field and its Liquid Glass presentation. Apply the
/// selection after the field editor becomes first responder, because AppKit's
/// default focus behavior otherwise replaces the requested selection.
struct StudyNoteTitleField: View {
    @Binding var title: String
    let noteID: UUID
    let destination: BibleReferencePersonalDestination?
    let navigationID: UUID
    @State private var appliedID: UUID?
    @FocusState private var focused: Bool
    var body: some View {
        TextField(L("Título de la nota"), text: $title).macInputStyle().focused($focused)
            .onAppear(perform: requestSelection)
            .onChange(of: navigationID) { requestSelection() }
            .onChange(of: noteID) { requestSelection() }
            .onChange(of: focused) { if focused { applySelection() } }
    }
    private func requestSelection() {
        guard appliedID != navigationID,
              StudyNoteTitleSearchTarget.range(destination, noteID: noteID, title: title) != nil else { return }
        if focused { applySelection() } else { focused = true }
    }
    private func applySelection() {
        let token = navigationID
        DispatchQueue.main.async {
            guard focused, navigationID == token, appliedID != token,
                  let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                  StudyNoteTitleSearchTarget.apply(destination, noteID: noteID, title: title, editor: editor) else { return }
            appliedID = token
        }
    }
}
