import Foundation
import Testing
@testable import MacRebuild

@MainActor struct AppPreferencesTests {
    @Test func appearanceReadingAndHoverPersistWithoutOverwritingUnrelatedChoices() throws {
        let name = "org.libronx.preferences-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("red", forKey: "applicationIcon.approved02.variant.v1")
        var applied: [AppAppearance] = []
        let preferences = AppPreferences(defaults: defaults, applyAppearance: { applied.append($0) })
        #expect(preferences.appearance == .system && preferences.readingScale == 1 && preferences.hoverNotes)
        preferences.appearance = .light; preferences.appearance = .dark
        preferences.readingScale = 1.25; preferences.hoverNotes = false
        let reopened = AppPreferences(defaults: defaults, applyAppearance: { applied.append($0) })
        reopened.applySavedAppearance()
        #expect(reopened.appearance == .dark && reopened.readingScale == 1.25 && !reopened.hoverNotes)
        #expect(applied == [.light, .dark, .dark])
        reopened.readingScale = .nan
        #expect(reopened.readingScale == 1.25)
        #expect(defaults.string(forKey: "applicationIcon.approved02.variant.v1") == "red")
    }
    @Test func corruptValuesFallBackToAValidPresentation() throws {
        let name = "org.libronx.preferences-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("future", forKey: AppPreferences.appearanceKey)
        defaults.set(-100, forKey: AppPreferences.readingScaleKey)
        let preferences = AppPreferences(defaults: defaults, applyAppearance: { _ in })
        #expect(preferences.appearance == .system && preferences.readingScale == 1)
    }
}
