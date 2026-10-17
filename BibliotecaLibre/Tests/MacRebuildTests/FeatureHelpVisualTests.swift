import AppKit
import SwiftUI
import Testing
@testable import MacRebuild

@MainActor struct FeatureHelpVisualTests {
    @Test func instructionalDiagramsRenderAcrossEveryLanguageWithoutChangingPreferences() throws {
        let original = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
        let output = ProcessInfo.processInfo.environment["LIBRONX_HELP_VISUAL_OUTPUT"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let visualKeys = ["Texto de ejemplo", "Aa", "Agregar carpeta", "Biblioteca", "Abrir directorio", "Grupos",
            "Referencia bíblica", "Descargar actualización", "Verificar", "Instalar", "Cambios de esta versión", "Buscar",
            "Explorador temático", "Abrir recurso", "Vista previa", "Copiar", "Referencia", "Nuevo documento", "Editar", "Guardar",
            "Favoritos", "Abrir", "Lectura", "Exportar", "Imprimir…", "Inicio", "Restaurar las lecturas anteriores", "Área de trabajo guardada"]
        for language in AppLanguage.allCases {
            for key in visualKeys { #expect(AppStrings.catalog[key]?[language.rawValue]?.isEmpty == false, "Missing diagram label: \(key)") }
            for topic in FeatureHelpTopic.allCases where topic != .information {
                let renderer = ImageRenderer(content: FeatureHelpVisual(topic: topic, language: language)
                    .padding(16).frame(width: 460).environment(\.locale, language.locale))
                let image = try #require(renderer.nsImage, "Diagram \(topic) did not render in \(language)")
                #expect(image.size.width == 460 && image.size.height > 40 && image.size.height < 300)
            }
            if let output {
                let samples: [FeatureHelpTopic] = [.workspace, .reading, .hoverNotes, .groups, .library, .updates]
                let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 16) {
                    ForEach(samples, id: \.rawValue) { topic in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(AppStrings.text(topic.title, language: language)).font(.headline)
                            FeatureHelpVisual(topic: topic, language: language)
                        }
                    }
                }.padding(20).frame(width: 520).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.locale, language.locale)
                    .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight))
                let image = try #require(renderer.nsImage)
                let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("help-overview-\(language.rawValue).png"))
            }
        }
        #expect(UserDefaults.standard.string(forKey: AppLanguage.defaultsKey) == original)
    }
}
