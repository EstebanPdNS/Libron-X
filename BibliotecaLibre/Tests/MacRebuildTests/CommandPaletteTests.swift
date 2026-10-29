import Testing
@testable import MacRebuild

@Suite @MainActor struct CommandPaletteTests {
    @Test func matchingUsesTranslatedNamesAndPreservesUniqueCommands() {
        let all = WorkspacePaletteCommand.matching("")
        #expect(!all.isEmpty && Set(all.map(\.id)).count == all.count)
        for command in all {
            #expect(AppStrings.catalog[command.title] != nil)
            let name = L(command.title)
            #expect(WorkspacePaletteCommand.matching(name.uppercased()).contains { $0.id == command.id })
        }
        #expect(WorkspacePaletteCommand.matching("NonexistentCommandToken529").isEmpty)
    }
}
