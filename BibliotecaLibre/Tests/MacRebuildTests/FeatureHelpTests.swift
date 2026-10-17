import AppKit
import Testing
@testable import MacRebuild

struct FeatureHelpTests {
    @Test func everyFeatureHasDetailedBundledHelpInAllInterfaceLanguages() {
        for topic in FeatureHelpTopic.allCases {
            #expect(!topic.paragraphs.isEmpty)
            for key in [topic.title] + topic.paragraphs {
                #expect(!key.hasPrefix("help."))
                for language in AppLanguage.allCases {
                    #expect(AppStrings.catalog[key]?[language.rawValue]?.isEmpty == false, "Missing help: \(key)")
                }
            }
        }
    }
    @Test func controlsResolveIndependentlyOfTheirSettingsWindowAndOriginalBookTextIsIgnored() {
        for language in AppLanguage.allCases {
            func label(_ key: String) -> String { AppStrings.text(key, language: language) }
            #expect(FeatureHelpTopic.resolve(labels: [label("Tamaño predeterminado")], windowTitle: label("General"), language: language) == .reading)
            #expect(FeatureHelpTopic.resolve(labels: [label("Mostrar notas al mantener el puntero")], windowTitle: label("Lectura"), language: language) == .hoverNotes)
            #expect(FeatureHelpTopic.resolve(labels: [label("Idioma de la interfaz")], windowTitle: label("General"), language: language) == .language)
            #expect(FeatureHelpTopic.resolve(labels: [label("Abrir directorio")], windowTitle: label("Biblioteca"), language: language) == .directory)
            #expect(FeatureHelpTopic.resolve(labels: ["Unknown source book title"], windowTitle: label("Grupos"), language: language) == .groups)
            #expect(FeatureHelpTopic.resolve(labels: [label("Cambios de esta versión")], windowTitle: label("Actualizaciones"), language: language) == .changelog)
            #expect(FeatureHelpTopic.resolve(labels: ["Dark"], windowTitle: "", language: language) == .appearance)
        }
    }
    @MainActor @Test func contextualHelpPreservesExistingActionsAndNeverDuplicatesItself() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Select All", action: nil, keyEquivalent: ""))
        FeatureHelp.shared.addItem(to: menu, topic: .reading)
        FeatureHelp.shared.addItem(to: menu, topic: .library)
        #expect(menu.items.prefix(2).map(\.title) == ["Copy", "Select All"])
        #expect(menu.items.count == 4)
        #expect(menu.items.last?.title == L("¿Qué es esto?"))
        #expect(menu.items.last?.representedObject as? String == FeatureHelpTopic.library.rawValue)
    }
    @MainActor @Test func helpWindowsFitTheirLocalizedContentsAndRespectSmallScreens() {
        for language in AppLanguage.allCases {
            for topic in FeatureHelpTopic.allCases {
                let natural = FeatureHelpWindowLayout.fittingSize(topic: topic, language: language,
                    width: 540, maximumHeight: 2000)
                #expect(natural.width == 540 && natural.height > 100 && natural.height < 1100)
                let limited = FeatureHelpWindowLayout.fittingSize(topic: topic, language: language,
                    width: 540, maximumHeight: 300)
                #expect(limited.height == min(natural.height, 300))
            }
        }
        let workspace = FeatureHelpWindowLayout.fittingSize(topic: .workspace, language: .spanish,
            width: 540, maximumHeight: 2000)
        #expect(workspace.height < 400, "A short explanation must not reserve the old 560-point window height")
    }

}
