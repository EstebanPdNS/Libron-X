import AppKit
import SwiftUI
import LibronixCore

/// Personal annotations are an overlay; source text and UTF-16 addresses stay intact.
struct ReaderPersonalNoteLink: Equatable {
    let documentID: UUID
    let noteID: UUID
    let title: String
    let ordinal: Int
    let fingerprint: String
    let range: NSRange
}
@MainActor extension WorkspacePersonalState {
    func noteLinks(for resource: LibraryResource) -> [ReaderPersonalNoteLink] {
        documents.flatMap { document in
            document.notes.compactMap { note in
                let anchor = note.effectiveAnchor
                guard let location = anchor.location, location.resolve(in: [resource]) != nil,
                      let fingerprint = location.textFingerprint, let selection = anchor.selection,
                      selection.location >= 0, selection.length > 0 else { return nil }
                return ReaderPersonalNoteLink(documentID: document.id, noteID: note.id, title: note.title,
                    ordinal: location.sectionOrdinal, fingerprint: fingerprint, range: selection.nsRange)
            }
        }
    }
}
@MainActor enum ReaderPersonalNoteAttributes {
    static func matching(_ links: [ReaderPersonalNoteLink], text: String, ordinal: Int?) -> [ReaderPersonalNoteLink] {
        let fingerprint = LibrarySearchService.textFingerprint(text)
        return links.filter { $0.ordinal == ordinal && $0.fingerprint == fingerprint && Range($0.range, in: text) != nil }
    }
    static func install(_ links: [ReaderPersonalNoteLink], in text: NSMutableAttributedString) {
        for link in links where Range(link.range, in: text.string) != nil {
            text.addAttributes([.link: URL(string: "libronx-note://\(link.documentID.uuidString)/\(link.noteID.uuidString)")!,
                .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor.linkColor,
                .foregroundColor: NSColor.linkColor, .toolTip: link.title], range: link.range)
        }
    }
}
@MainActor extension StudyWorkspace {
    func editPersonalNote(_ link: ReaderPersonalNoteLink) {
        guard personal.documents.contains(where: { $0.id == link.documentID && $0.notes.contains(where: { $0.id == link.noteID }) }) else { return }
        personal.selectedDocumentID = link.documentID
        pendingNoteID = link.noteID; activeTool = .documents
    }
}

@MainActor final class ReaderPersonalNotePreview: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private static var pinned: [ObjectIdentifier: ReaderPersonalNotePreview] = [:]
    var personal: WorkspacePersonalState?
    var edit: ((ReaderPersonalNoteLink) -> Void)?
    func show(_ links: [ReaderPersonalNoteLink], in view: NSView, rect: NSRect) {
        guard let personal, let anchor = view.window?.contentView, !links.isEmpty else { return }
        close()
        let popover = NSPopover(); self.popover = popover
        popover.behavior = .applicationDefined; popover.animates = false; popover.delegate = self
        Self.pinned[ObjectIdentifier(self)] = self
        popover.contentViewController = NSHostingController(rootView: PersonalNotePreviewView(personal: personal, links: links,
            edit: { [weak self] link in
                guard let self else { return }; self.close(); self.edit?(link)
            }, close: { [weak self] in self?.close() }).modifier(AppInterfaceLanguage()))
        popover.contentSize = NSSize(width: 400, height: 320)
        popover.show(relativeTo: anchor.convert(rect, from: view), of: anchor, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func close() {
        popover?.delegate = nil; popover?.close(); popover = nil
        Self.pinned.removeValue(forKey: ObjectIdentifier(self))
    }
    func popoverDidClose(_ notification: Notification) { close() }
}
private struct PersonalNotePreviewView: View {
    let personal: WorkspacePersonalState
    let links: [ReaderPersonalNoteLink]
    let edit: (ReaderPersonalNoteLink) -> Void
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Mis notas")).font(.headline)
                Spacer()
                Button(action: close) { MacToolbarLabel(L("Cerrar nota"), "xmark") }
            }.buttonStyle(.borderless).padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(links, id: \.noteID) { link in
                        if let note = personal.documents.first(where: { $0.id == link.documentID })?.notes.first(where: { $0.id == link.noteID }) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(note.title).font(.headline).textSelection(.enabled)
                                Text(PersonalReferenceProjection.body(note).text)
                                    .font(.system(size: 18, design: .serif))
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }
                        }
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack {
                if links.count == 1, let link = links.first {
                    Button(L("Editar nota")) { edit(link) }
                } else {
                    Menu(L("Editar nota")) {
                        ForEach(links, id: \.noteID) { link in
                            Button(link.title) { edit(link) }
                        }
                    }
                }
                Spacer()
            }.modifier(MacPanelControlPresentation()).padding(10)
        }.frame(width: 400, height: 320)
    }
}
