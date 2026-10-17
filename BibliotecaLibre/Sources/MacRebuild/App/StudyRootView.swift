import SwiftUI

struct StudyRootView: View {
    let workspace: StudyWorkspace
    let lifecycle: RebuildLifecycle
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        StudyDesktop(workspace: workspace)
            .frame(minWidth: 800, minHeight: 500)
            .task {
                lifecycle.workspace = workspace
                if await lifecycle.startup.launch(workspace, preferences: .shared) { openWindow(id: "library") }
            }
    }
}
