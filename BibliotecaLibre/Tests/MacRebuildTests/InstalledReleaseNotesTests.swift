import Foundation
import Testing
@testable import MacRebuild

struct InstalledReleaseNotesTests {
    @Test func bundledNotesMatchOnlyTheirExactInstalledVersionAndHaveAllTranslations() throws {
        let notes = try #require(InstalledReleaseNotes.current(version: "0.1.1-beta.1"))
        #expect(notes.changes.count >= 7)
        #expect(Set(notes.changes).count == notes.changes.count)
        for key in notes.changes {
            for language in AppLanguage.allCases {
                #expect(AppStrings.catalog[key]?[language.rawValue]?.isEmpty == false)
            }
        }
        let earlier = try #require(InstalledReleaseNotes.current(version: "0.1"))
        #expect(earlier.changes != notes.changes)
        #expect(InstalledReleaseNotes.current(version: "0.1.1-beta.2") == nil)
        #expect(InstalledReleaseNotes.current(version: "99.0.0") == nil)
    }
}
