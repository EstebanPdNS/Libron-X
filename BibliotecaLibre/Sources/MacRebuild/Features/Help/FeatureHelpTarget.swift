import AppKit
import SwiftUI

/// Passive geometry tags provide exact help for custom SwiftUI controls whose
/// native accessibility hit-test may stop at the hosting view. They never hit-test
/// as input targets and never replace a control's existing context menu.
struct FeatureHelpTarget: NSViewRepresentable {
    let topic: FeatureHelpTopic
    func makeNSView(context: Context) -> HelpRegionView { HelpRegionView(topic: topic) }
    func updateNSView(_ view: HelpRegionView, context: Context) { view.topic = topic }
    static func dismantleNSView(_ view: HelpRegionView, coordinator: ()) { FeatureHelp.shared.unregister(view) }
}
@MainActor final class HelpRegionView: NSView {
    var topic: FeatureHelpTopic
    init(topic: FeatureHelpTopic) { self.topic = topic; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { FeatureHelp.shared.register(self) }
        else { FeatureHelp.shared.unregister(self) }
    }
}
extension View {
    func featureHelpTarget(_ topic: FeatureHelpTopic) -> some View {
        background(FeatureHelpTarget(topic: topic))
            .accessibilityIdentifier("feature-help." + topic.rawValue)
    }
}
