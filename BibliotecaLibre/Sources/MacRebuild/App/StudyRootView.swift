import SwiftUI

struct StudyRootView: View {
    let workspace: StudyWorkspace
    let lifecycle: RebuildLifecycle
    @Environment(\.openWindow) private var openWindow
    @RebuildViewState private var ready = false
    @RebuildViewState private var pendingLink: URL?
    var body: some View {
        StudyDesktop(workspace: workspace)
            .frame(minWidth: 800, minHeight: 500)
            .task {
                lifecycle.workspace = workspace
                if await lifecycle.startup.launch(workspace, preferences: .shared) { openWindow(id: "library") }
                ready = true
                if let link = pendingLink { pendingLink = nil; workspace.openReaderLocationLink(link) }
            }
            .onOpenURL { url in
                if ready { workspace.openReaderLocationLink(url) } else { pendingLink = url }
            }
    }
}
