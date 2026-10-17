import AppKit
import SwiftUI

enum HelpTopic {
    case windows, zoom, groups, sync, imports, library, dictionary, general, updates, information
    var native: FeatureHelpTopic {
        switch self {
        case .windows: .workspace; case .zoom: .reading; case .groups: .groups; case .sync: .synchronization
        case .imports: .imports; case .library: .library; case .dictionary: .dictionary; case .general: .appearance
        case .updates: .updates; case .information: .information
        }
    }
}
struct HelpButton: View {
    let topic: HelpTopic
    var body: some View {
        Button { FeatureHelp.shared.show(topic.native) } label: { Label(L("¿Qué es esto?"), systemImage: "questionmark.circle") }
            .labelStyle(.iconOnly).buttonStyle(.borderless).help(L("¿Qué es esto?"))
    }
}
struct HelpMenuItem: View {
    let topic: HelpTopic
    var body: some View { Button(L("¿Qué es esto?"), systemImage: "questionmark.circle") { FeatureHelp.shared.show(topic.native) } }
}
extension View {
    func contextHelp(_ topic: HelpTopic) -> some View { featureHelpTarget(topic.native) }
}
@MainActor enum ContextHelp {
    static func append(to menu: NSMenu?, topic: HelpTopic, target: AnyObject, action: Selector) -> NSMenu {
        let menu = menu ?? NSMenu(); FeatureHelp.shared.addItem(to: menu, topic: topic.native); return menu
    }
}
