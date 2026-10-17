import AppKit
import SwiftUI

/// Scoped to the workspace window. Editing fields, sheets, dialogs and modified
/// arrows retain their system behavior; bare arrows cycle the active Bible or dictionary.
struct BibleVersionKeyboardRouting: NSViewRepresentable {
    let workspace: StudyWorkspace
    func makeNSView(context: Context) -> KeyView { KeyView(workspace: workspace) }
    func updateNSView(_ view: KeyView, context: Context) { }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }
    @MainActor final class KeyView: NSView {
        let workspace: StudyWorkspace
        var monitor: Any?
        init(workspace: StudyWorkspace) { self.workspace = workspace; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window, window.isKeyWindow,
                          window.attachedSheet == nil, event.window === window,
                          window.childWindows?.contains(where: { $0.isVisible }) != true,
                          self.workspace.activeTool == nil, self.workspace.error == nil,
                          !self.workspace.showsHome,
                          Self.accepts(event, responder: window.firstResponder),
                          let reader = self.workspace.activeReader, reader.canSynchronizeBible || reader.isDictionary else { return false }
                    if reader.isDictionary { self.workspace.cycleDictionary(reader, backwards: event.keyCode == 123) }
                    else { self.workspace.cycleBibleVersion(reader, backwards: event.keyCode == 123) }
                    return true
                }
                return handled ? nil : event
            }
        }
        static func accepts(_ event: NSEvent, responder: NSResponder?) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            guard modifiers.isEmpty, [123, 124].contains(event.keyCode) else { return false }
            if let text = responder as? NSTextView, text.isEditable { return false }
            if responder is NSControl { return false }
            return true
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    }
}
