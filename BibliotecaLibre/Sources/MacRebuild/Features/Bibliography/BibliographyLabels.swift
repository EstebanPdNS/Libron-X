import Foundation
import LibronixCore

extension BibliographyField {
    var title:String {
        switch self {
        case .title:"Título";case .originalTitle:"Título original";case .subtitle:"Subtítulo";case .authors:"Autor";case .contributors:"Colaboradores"
        case .year:"Año";case .originalYear:"Año original";case .publisher:"Editorial";case .edition:"Edición"
        case .series:"Colección";case .languages:"Idioma";case .abbreviation:"Abreviatura"
        }
    }
}
extension BibliographyCertainty {
    var title:String {
        switch self { case .declared:"Declarado";case .inferred:"Inferido";case .unverified:"Sin evidencia";case .unknown:"Desconocido" }
    }
}
extension BibliographyOrder {
    var title:String { switch self { case .authorTitle:"Autor y título";case .title:"Título";case .yearTitle:"Año y título" } }
}
@MainActor enum BibliographyLocalization {
    static var labels:BibliographyReportLabels {
        var labels=BibliographyReportLabels()
        labels.title=L("Bibliografía");labels.unknown=L("Desconocido");labels.scope=L("Ámbito");labels.generated=L("Generado")
        labels.resource=L("Recurso");labels.partial=L("Bibliografía con miembros pendientes");labels.issue=L("Miembro pendiente")
        labels.language=AppPreferences.shared.language.rawValue
        labels.fields=Dictionary(uniqueKeysWithValues:BibliographyField.allCases.map { ($0,L($0.title)) })
        labels.certainties=[.declared:L("Declarado"),.inferred:L("Inferido"),.unverified:L("Sin evidencia"),.unknown:L("Desconocido")]
        labels.scopes=[.library:L("Toda la biblioteca"),.collections:L("Colecciones"),.selection:L("Selección")]
        labels.reasons=[.missingCollection:L("Colección no disponible"),.missingResource:L("Recurso no disponible"),.changedIdentity:L("La identidad del recurso cambió.")]
        return labels
    }
}
