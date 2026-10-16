import Foundation
import Observation

/// Selection in the window list must not focus a reader until explicitly activated.
@MainActor @Observable final class WorkspaceWindowSelection {
    let workspace: StudyWorkspace
    var selectedID: UUID?
    init(workspace: StudyWorkspace) {
        self.workspace = workspace
        selectedID = workspace.activeID ?? workspace.orderedReaders.first?.id
    }
    var readers: [ReaderSession] { workspace.orderedReaders }
    var selectedReader: ReaderSession? { readers.first { $0.id == selectedID } }
    func reconcile() {
        guard selectedReader == nil else { return }
        selectedID = readers.first { $0.id == workspace.activeID }?.id ?? readers.first?.id
    }
    @discardableResult func activateSelected() -> Bool {
        guard let reader = selectedReader else { return false }
        workspace.activate(reader)
        workspace.activeTool = nil
        return true
    }
    @discardableResult func closeSelected() -> Bool {
        guard let reader = selectedReader,
              let index = readers.firstIndex(where: { $0 === reader }) else { return false }
        let remaining = readers.filter { $0 !== reader }
        workspace.close(reader)
        selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        return true
    }
}
