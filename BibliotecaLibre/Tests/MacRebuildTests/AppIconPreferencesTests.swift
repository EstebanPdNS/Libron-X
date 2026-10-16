import AppKit
import Foundation
import Testing
@testable import MacRebuild

@MainActor struct AppIconPreferencesTests {
    @Test func firstLaunchAndUnknownChoiceUseRedWithoutOverwritingOtherPreferences() throws {
        let name = "org.libronx.icon-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppIconPreferences(defaults: defaults).selected == .red)
        defaults.set("future", forKey: AppIconPreferences.defaultsKey)
        defaults.set(21, forKey: "readerFontSize.v1")
        #expect(AppIconPreferences(defaults: defaults).selected == .red)
        #expect(defaults.integer(forKey: "readerFontSize.v1") == 21)
        #expect(defaults.string(forKey: AppIconPreferences.defaultsKey) == "future")
    }

    @Test func bothApprovedIconsLoadAndChoiceSurvivesReopeningWithoutModifyingBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IconTests-\(UUID()).app")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = root.appendingPathComponent("Contents/Info.plist")
        let metadata = ["CFBundleIdentifier": "org.libronx.icon-fixture", "CFBundlePackageType": "APPL", "CFBundleIconFile": "LibronX-Red.icns"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: info)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/AppIcons/Approved-Cristal")
        var original: [String: Data] = [:]
        for variant in AppIconVariant.allCases {
            let name = variant.resourceName + ".icns", bytes = try Data(contentsOf: source.appendingPathComponent(name))
            try bytes.write(to: resources.appendingPathComponent(name)); original[name] = bytes
        }
        let bundle = try #require(Bundle(url: root))
        let name = "org.libronx.icon-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var applications = 0
        let preferences = AppIconPreferences(defaults: defaults, bundle: bundle, applyImage: { image in
            #expect(image.isValid); applications += 1
        })
        for variant in AppIconVariant.allCases { #expect(preferences.image(for: variant)?.isValid == true) }
        preferences.select(.black)
        #expect(preferences.selected == .black && applications == 1 && preferences.message == nil)
        let reopened = AppIconPreferences(defaults: defaults, bundle: bundle, applyImage: { _ in applications += 1 })
        #expect(reopened.selected == .black)
        reopened.applySavedSelection()
        #expect(applications == 2)
        reopened.select(.red)
        #expect(reopened.selected == .red && defaults.string(forKey: AppIconPreferences.defaultsKey) == "red")
        for (name, bytes) in original { #expect(try Data(contentsOf: resources.appendingPathComponent(name)) == bytes) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Icon\r").path))
        #expect(try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: String] == metadata)
    }

    @Test func missingIconDoesNotApplyOrReplaceSavedChoice() throws {
        let name = "org.libronx.icon-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("red", forKey: AppIconPreferences.defaultsKey)
        var applications = 0
        let preferences = AppIconPreferences(defaults: defaults, bundle: Bundle(for: IconBundleSentinel.self),
                                             applyImage: { _ in applications += 1 })
        preferences.select(.black); preferences.applySavedSelection()
        #expect(preferences.selected == .red && applications == 0 && preferences.message != nil)
        #expect(defaults.string(forKey: AppIconPreferences.defaultsKey) == "red")
    }
}
private final class IconBundleSentinel: NSObject {}
