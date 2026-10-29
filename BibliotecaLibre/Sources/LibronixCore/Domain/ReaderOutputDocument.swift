import Foundation

public enum ReaderOutputScope: String, Codable, Sendable { case article, chapter, selection }
public enum ReaderOutputRequest: Sendable { case reading, selection(SearchTextRange) }
public struct ReaderOutputParagraph: Sendable, Equatable {
    public let text: String
    public let style: LegacyParagraphStyle?
    public let spans: [ReaderOutputSpan]
    public init(text: String, style: LegacyParagraphStyle?, spans: [ReaderOutputSpan]) {
        self.text = text; self.style = style; self.spans = spans
    }
}
public struct ReaderOutputSpan: Sendable, Equatable {
    public let range: SearchTextRange
    public let style: LegacyCharacterStyle?
    public init(range: SearchTextRange, style: LegacyCharacterStyle?) { self.range = range; self.style = style }
}
public struct ReaderOutputSource: Sendable, Equatable {
    public let sectionOrdinal: Int
    public let decodedTextSHA256: String
    public let selectedRange: SearchTextRange
    /// A source row has its own decoded-body coordinates. Nil denotes the
    /// existing whole-article projection; row offsets must never open a reader.
    public let verseReference: String?
    public init(sectionOrdinal: Int, decodedTextSHA256: String, selectedRange: SearchTextRange, verseReference: String? = nil) {
        self.sectionOrdinal = sectionOrdinal; self.decodedTextSHA256 = decodedTextSHA256
        self.selectedRange = selectedRange; self.verseReference = verseReference
    }
}
public struct ReaderOutputDocument: Sendable, Equatable {
    public let resourceID: String
    public let originalResourceID: String?
    public let title: String
    public let scope: ReaderOutputScope
    public let scopeLabel: String
    public let references: [String]
    public let paragraphs: [ReaderOutputParagraph]
    public let sources: [ReaderOutputSource]
    public let typography: LegacyTypography
    public let bibliographicCitation: String
    public let createdUTC: Date
    public var plainText: String { paragraphs.map(\.text).joined(separator: "\n") }
}
public enum ReaderOutputError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedFormat, ambiguousChapter, invalidChapter, incompleteChapter, unsupportedContent, invalidSelection, limitExceeded
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Este formato todavía no permite preparar una salida del lector."
        case .ambiguousChapter: "El directorio no identifica un capítulo único para esta posición."
        case .invalidChapter: "Las referencias recuperadas no coinciden con los límites del capítulo."
        case .incompleteChapter: "El capítulo contiene una discontinuidad; no se exporta como si estuviera completo."
        case .unsupportedContent: "La salida de este artículo contiene tablas, gráficos u objetos cuya representación todavía está pendiente."
        case .invalidSelection: "La selección no coincide con el texto confirmado del lector."
        case .limitExceeded: "El conjunto solicitado supera el límite de preparación de salida."
        }
    }
}
