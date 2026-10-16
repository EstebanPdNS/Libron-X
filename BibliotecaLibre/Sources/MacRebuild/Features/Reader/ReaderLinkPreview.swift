import AppKit
import LibronixCore
import Observation
import SwiftUI

/// A preview owns its pending read, never changes the source reader's history,
/// and discards results after dismissal or a different link/document request.
@MainActor @Observable final class ReaderLinkPreviewState {
    private(set) var resource: LibraryResource?
    private(set) var page: ReaderPage?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var link: LegacyInlineLink?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let loader: ReaderSession.Loader
    init(loader: @escaping ReaderSession.Loader = ReaderSession.read) { self.loader = loader }
    func load(_ link: LegacyInlineLink, resource: LibraryResource, destination requested: ReaderDestination? = nil) {
        cancel(); let token = generation
        self.resource = resource; self.link = link; page = nil; error = nil; isLoading = true
        task = Task { [weak self, loader] in
            do {
                let destination = try requested ?? Self.destination(for: link, resource: resource)
                let result = try await loader(resource, destination)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.page = result; self.isLoading = false; self.task = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.error = error.localizedDescription; self.isLoading = false; self.task = nil
            }
        }
    }
    nonisolated static func destination(for link: LegacyInlineLink, resource: LibraryResource) throws -> ReaderDestination {
        switch link.target {
        case let .article(ordinal): return .init(ordinal: ordinal)
        case let .bible(reference):
            if let edition = reference.edition,
               resource.location.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(edition) != .orderedSame {
                throw RebuildError.referenceEditionUnavailable(edition)
            }
            let passage = reference.passage
            return .init(ordinal: 0,
                reference: "\(passage.start.sourceBook) \(passage.start.chapter):\(passage.start.verse)",
                endReference: passage.start == passage.end ? nil : "\(passage.end.sourceBook) \(passage.end.chapter):\(passage.end.verse)",
                requiredEdition: reference.edition)
        }
    }
    func movePassage(by delta: Int) {
        guard !isLoading, let page, let index = page.passagePartIndex,
              let destination = page.passageDestination(at: index + delta), let link, let resource else { return }
        load(link, resource: resource, destination: destination)
    }
    func fail(_ link: LegacyInlineLink, error: Error) {
        cancel(); self.link = link; page = nil; resource = nil; self.error = error.localizedDescription
    }
    func cancel() { generation += 1; task?.cancel(); task = nil; isLoading = false }
    deinit { task?.cancel() }
}

@MainActor final class ReaderLinkPreviewController: NSObject, NSPopoverDelegate {
    var resource: LibraryResource?
    var onOpen: (LibraryResource, ReaderDestination, Bool) -> Void = { _, _, _ in }
    var resolveResource: ((LibraryResource, LegacyInlineLink) throws -> LibraryResource)?
    private let state = ReaderLinkPreviewState()
    private var popover = NSPopover()
    private var hoverTask: Task<Void, Never>?
    private var pending: LegacyInlineLink?
    private var displayed: LegacyInlineLink?

    func show(_ link: LegacyInlineLink, at rect: NSRect, in view: NSView, hovering: Bool) {
        if hovering && !AppPreferences.shared.hoverNotes { cancelHover(); return }
        if displayed == link && popover.isShown {
            if !hovering { focusContent() }
            return
        }
        if hovering && pending == link { return }
        cancelHover(); pending = link
        if hovering {
            hoverTask = Task { @MainActor [weak self, weak view] in
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard let self, let view, self.pending == link else { return }
                self.present(link, at: rect, in: view, focus: false)
            }
        } else { present(link, at: rect, in: view, focus: true) }
    }
    func openSourceLink(_ link: LegacyInlineLink, newReader: Bool, window: NSWindow?) {
        guard let resource else { return }
        do {
            let target = try resolveResource?(resource, link) ?? resource
            let destination = try ReaderLinkPreviewState.destination(for: link, resource: target)
            dismiss(); onOpen(target, destination, newReader)
        } catch {
            guard let window else { return }
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: window)
        }
    }
    func cancelHover() { hoverTask?.cancel(); hoverTask = nil; pending = nil }
    func dismiss() {
        cancelHover(); state.cancel(); displayed = nil
        if popover.isShown { popover.close() }
    }
    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        cancelHover(); state.cancel(); displayed = nil
    }
    private func focusContent() {
        guard let view = popover.contentViewController?.view, let window = view.window else { return }
        // An explicitly opened note is a keyboard interaction surface. Hover
        // previews keep the reading window's focus until the user clicks.
        window.makeKey()
        window.makeFirstResponder(view)
    }
    private func present(_ link: LegacyInlineLink, at rect: NSRect, in view: NSView, focus: Bool) {
        guard let resource, view.window != nil else { cancelHover(); return }
        cancelHover()
        if popover.isShown { popover.delegate = nil; popover.close() }
        popover = NSPopover()
        displayed = link
        do { state.load(link, resource: try resolveResource?(resource, link) ?? resource) }
        catch { state.fail(link, error: error) }
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ReaderLinkPreviewView(state: state, resource: resource,
            open: { [weak self] destination, newReader in
                guard let self, let targetResource = self.state.resource else { return }
                self.dismiss(); self.onOpen(targetResource, destination, newReader)
            }, resolveResource: { [weak self] source, link in
                try self?.resolveResource?(source, link) ?? source
            }, openNested: { [weak self] resource, destination, newReader in
                guard let self else { return }
                self.dismiss(); self.onOpen(resource, destination, newReader)
            }, close: { [weak self] in self?.dismiss() }))
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        if focus { focusContent() }
    }
}

private struct ReaderLinkPreviewView: View {
    let state: ReaderLinkPreviewState
    let resource: LibraryResource
    let open: (ReaderDestination, Bool) -> Void
    let resolveResource: (LibraryResource, LegacyInlineLink) throws -> LibraryResource
    let openNested: (LibraryResource, ReaderDestination, Bool) -> Void
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LF("Nota o referencia {label}", ["label": state.link?.label ?? ""])).font(.headline)
                Spacer()
                Button(action: close) { MacToolbarLabel(L("Cerrar nota"), "xmark") }.buttonStyle(.borderless)
            }.padding(12)
            Divider()
            if state.isLoading { ProgressView("Cargando nota…").frame(height: 180) }
            else if let error = state.error {
                Text(error).textSelection(.enabled).padding().frame(minHeight: 100)
            } else if let page = state.page {
                ReaderTextView(text: page.text, selection: page.selection, identity: page.destination,
                    content: page.content, typography: page.typography, graphics: page.graphics,
                    scale: 1.25, resource: state.resource ?? resource, inlineLinks: page.inlineLinks,
                    onOpenLink: openNested, resolveLinkResource: resolveResource, activate: {})
                    .frame(height: 220)
                if page.passageParts.count > 1, let index = page.passagePartIndex {
                    HStack {
                        Button { state.movePassage(by: -1) } label: { MacToolbarLabel(L("Parte anterior del pasaje"), "chevron.left") }
                            .disabled(index == 0)
                        Text(LF("Parte {current} de {total}", ["current": String(index + 1), "total": String(page.passageParts.count)])).font(.caption)
                        Button { state.movePassage(by: 1) } label: { MacToolbarLabel(L("Parte siguiente del pasaje"), "chevron.right") }
                            .disabled(index + 1 == page.passageParts.count)
                    }.buttonStyle(.borderless).padding(6)
                }
            }
            Divider()
            HStack {
                Button(L("Abrir aquí")) { if let page = state.page { open(page.destination, false) } }
                Button(L("Abrir en otra lectura")) { if let page = state.page { open(page.destination, true) } }
                Spacer()
            }.disabled(state.page == nil).padding(10)
        }.frame(width: 400)
    }
}
