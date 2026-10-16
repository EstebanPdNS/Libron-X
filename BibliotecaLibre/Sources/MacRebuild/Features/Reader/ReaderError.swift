import Foundation

/// Typed reader failures retain their meaning independently of presentation.
/// Rendering an error never translates an edition identifier or source text.
enum RebuildError: LocalizedError, Sendable {
    case bibleReferenceTargetUnavailable
    case referenceEditionUnavailable(String)
    case invalidPassagePart, passageReadLimit
    case unsupportedFormat, referenceNotFound, referenceSearchIncomplete

    var messageKey: String {
        switch self {
        case .bibleReferenceTargetUnavailable: "Abre una Biblia y elígela como destino de las referencias para seguir este enlace."
        case .referenceEditionUnavailable: "La referencia solicita la edición {edition}. Abre esa edición para seguir este enlace."
        case .invalidPassagePart: "Una parte del pasaje no conserva una referencia o un intervalo de texto válido."
        case .passageReadLimit: "El pasaje supera el límite de lectura. Elige un intervalo más corto."
        case .unsupportedFormat: "El lector de este formato todavía no está implementado en la nueva aplicación."
        case .referenceNotFound: "No se encontró esta referencia en el recurso."
        case .referenceSearchIncomplete: "La búsqueda alcanzó el límite de artículos antes de encontrar la referencia. El pasaje puede existir en este recurso."
        }
    }
    func message(language: AppLanguage) -> String {
        let values: [String: String]
        if case let .referenceEditionUnavailable(edition) = self { values = ["edition": edition] }
        else { values = [:] }
        return AppStrings.format(messageKey, language: language, values: values)
    }
    // LocalizedError can be read by detached loaders and Foundation's NSError
    // bridge. Read only the app's persisted choice, without accessing UI actors.
    var errorDescription: String? { message(language: AppLanguage.saved()) }
}
