import AppKit
import SwiftUI

/// Passive geometry tags provide exact help for custom SwiftUI controls whose
/// native accessibility hit-test may stop at the hosting view. They never hit-test
/// as input targets and never replace a control's existing context menu.
struct FeatureHelpTarget: NSViewRepresentable {
    let topic: FeatureHelpTopic
    var reader: ReaderSession? = nil
    var workspace: StudyWorkspace? = nil
    func makeNSView(context: Context) -> HelpRegionView { HelpRegionView(topic: topic, reader: reader, workspace: workspace) }
    func updateNSView(_ view: HelpRegionView, context: Context) { view.topic = topic; view.reader = reader; view.workspace = workspace }
    static func dismantleNSView(_ view: HelpRegionView, coordinator: ()) { FeatureHelp.shared.unregister(view) }
}
@MainActor final class HelpRegionView: NSView {
    var topic: FeatureHelpTopic
    weak var reader: ReaderSession?
    weak var workspace: StudyWorkspace?
    init(topic: FeatureHelpTopic, reader: ReaderSession? = nil, workspace: StudyWorkspace? = nil) {
        self.topic = topic; self.reader = reader; self.workspace = workspace; super.init(frame: .zero)
    }
    func isFrontmostReader(at point: NSPoint) -> Bool {
        guard let reader, let workspace else { return true }
        guard let root = window?.contentView, let canvas = PaneCanvasSurface.find(in: root) else { return false }
        return workspace.frontmostReader(at: canvas.convert(point, from: nil), canvas: canvas.bounds.size) === reader
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { FeatureHelp.shared.register(self) }
        else { FeatureHelp.shared.unregister(self) }
    }
}
private struct ReaderHelpScope {
    let reader: ReaderSession
    let workspace: StudyWorkspace
}
private struct ReaderHelpScopeKey: EnvironmentKey {
    static var defaultValue: ReaderHelpScope? { nil }
}
private extension EnvironmentValues {
    var readerHelpScope: ReaderHelpScope? {
        get { self[ReaderHelpScopeKey.self] }
        set { self[ReaderHelpScopeKey.self] = newValue }
    }
}
private struct ScopedFeatureHelpTarget: View {
    let topic: FeatureHelpTopic
    @Environment(\.readerHelpScope) private var scope
    var body: some View { FeatureHelpTarget(topic: topic, reader: scope?.reader, workspace: scope?.workspace) }
}
extension View {
    func readerHelpTarget(_ topic: FeatureHelpTopic, reader: ReaderSession, workspace: StudyWorkspace) -> some View {
        background(FeatureHelpTarget(topic: topic, reader: reader, workspace: workspace))
            .environment(\.readerHelpScope, ReaderHelpScope(reader: reader, workspace: workspace))
    }
    func featureHelpTarget(_ topic: FeatureHelpTopic) -> some View {
        background(ScopedFeatureHelpTarget(topic: topic))
            .accessibilityIdentifier("feature-help." + topic.rawValue)
    }
}
