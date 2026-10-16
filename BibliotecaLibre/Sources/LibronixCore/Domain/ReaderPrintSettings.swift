import Foundation

public enum ReaderPaper: String, Codable, Sendable, CaseIterable {
    case a4, letter
    public var width: Double { self == .a4 ? 595.2756 : 612 }
    public var height: Double { self == .a4 ? 841.8898 : 792 }
}
public struct ReaderPrintSettings: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var paper = ReaderPaper.a4
    public var landscape = false
    public var leftMargin = 54.0
    public var rightMargin = 54.0
    public var topMargin = 54.0
    public var bottomMargin = 54.0
    public var fontSize = 10.0
    public var pageNumbers = true
    public var footer = true
    public var showTitle = false
    public init() {}
    public var width: Double { landscape ? paper.height : paper.width }
    public var height: Double { landscape ? paper.width : paper.height }
    public func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        let values = [leftMargin,rightMargin,topMargin,bottomMargin,fontSize]
        guard values.allSatisfy(\.isFinite), (6...32).contains(fontSize),
              [leftMargin,rightMargin,topMargin,bottomMargin].allSatisfy({ (0...600).contains($0) }),
              width - leftMargin - rightMargin >= 64, height - topMargin - bottomMargin >= 64 else {
            throw PersonalStateError.invalid("El tamaño de letra o los márgenes no dejan una página válida.")
        }
        guard !(pageNumbers || showTitle) || topMargin >= 32,
              !footer || bottomMargin >= 28 else {
            throw PersonalStateError.invalid("La cabecera necesita un margen superior de al menos 32 pt y el pie, un margen inferior de al menos 28 pt. También puedes desactivarlos.")
        }
    }
}
