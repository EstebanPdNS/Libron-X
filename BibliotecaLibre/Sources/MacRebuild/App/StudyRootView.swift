import SwiftUI

struct StudyRootView: View {
    let workspace: StudyWorkspace
    let lifecycle: RebuildLifecycle
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        StudyDesktop(workspace: workspace)
            .frame(minWidth: 800, minHeight: 500)
            .onAppear {
                lifecycle.workspace = workspace
                if lifecycle.startup.launch(workspace, preferences: .shared) { openWindow(id: "library") }
            }
    }
}
