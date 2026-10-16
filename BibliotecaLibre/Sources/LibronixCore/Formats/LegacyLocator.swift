import Foundation

public enum LegacyLocatorError: Error, LocalizedError, Equatable, Sendable {
    case invalidSyntax, overflow, missingBase, missingCharacterTable, characterTableMismatch
    case ambiguousLabel, outsideArticle, incompatibleProjection, contextMismatch, resourceMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidSyntax: "La posición original no tiene una sintaxis compatible."
        case .overflow: "La posición original supera los límites de sus campos."
        case .missingBase: "Esta posición relativa necesita el destino base del artículo."
        case .missingCharacterTable: "El recurso no contiene la tabla de caracteres necesaria para verificar esta posición."
        case .characterTableMismatch: "La tabla de caracteres no coincide con los artículos del recurso."
        case .ambiguousLabel: "La etiqueta del artículo no identifica un destino único en este recurso."
        case .outsideArticle: "La posición original está fuera del artículo."
        case .incompatibleProjection: "El texto recuperado todavía no permite traducir esta posición original con certeza."
        case .contextMismatch: "El contexto conservado de la nota no coincide con esta edición del texto."
        case .resourceMismatch: "La identidad original del recurso no coincide con la edición elegida."
        }
    }
}

/// Observed bkid layout: two u16 resource-number components, one u32 number
/// and a trailing u16 field retained separately. Twenty runtime IDs agree;
/// this does not convert named identifiers or determine edition precedence.
public struct LegacyNumericResourceID: Sendable, Codable, Equatable {
    public let first: UInt16
    public let second: UInt16
    public let third: UInt32
    public let trailingField: UInt16
    public var identifier: String { "LLS:\(first).\(second).\(third)" }
    public static func fromBKIDHex(_ value: String?) -> LegacyNumericResourceID? {
        guard let value, value.utf8.count == 20,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        var bytes: [UInt8] = [], cursor = value.startIndex
        while cursor < value.endIndex {
            let end = value.index(cursor, offsetBy: 2)
            guard let byte = UInt8(value[cursor..<end], radix: 16) else { return nil }
            bytes.append(byte); cursor = end
        }
        func word(_ start: Int) -> UInt16 { UInt16(bytes[start]) | UInt16(bytes[start + 1]) << 8 }
        let third = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[4 + $1]) << ($1 * 8) }
        return .init(first: word(0), second: word(2), third: third, trailingField: word(8))
    }
}

/// Fields are original logical coordinates; parsing alone does not establish
/// their correspondence to decoded text. Relative OL can have a signed offset.
public struct LegacyRelativeLocator: Sendable, Codable, Equatable {
    public let offsetDelta: Int64
    public let lengthOverride: UInt32
    public let articleDelta: UInt32
    public static func parse(_ value: String) throws -> LegacyRelativeLocator {
        guard value.utf8.count <= 128 else { throw LegacyLocatorError.invalidSyntax }
        if value.hasPrefix("::OLA:") {
            let parts = value.dropFirst(6).split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { throw LegacyLocatorError.invalidSyntax }
            let values = try parts.map { try LegacyArticleLocator.unsigned(String($0)) }
            return .init(offsetDelta: Int64(values[0]), lengthOverride: values[1], articleDelta: values[2])
        }
        if value.hasPrefix("::OL:") {
            let parts = value.dropFirst(5).split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, let offset = Int32(parts[0]), !parts[0].isEmpty,
                  parts[0].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else { throw LegacyLocatorError.invalidSyntax }
            return .init(offsetDelta: Int64(offset), lengthOverride: try LegacyArticleLocator.unsigned(String(parts[1])), articleDelta: 0)
        }
        throw LegacyLocatorError.invalidSyntax
    }
}

public struct LegacyArticleLocator: Sendable, Codable, Equatable {
    public let articleID: UInt32
    public let articleLabel: String?
    public let offset: UInt32
    public let length: UInt32
    public let relative: LegacyRelativeLocator?

    public static func parse(_ source: String) throws -> LegacyArticleLocator {
        guard source.utf16.count <= 1_024 else { throw LegacyLocatorError.invalidSyntax }
        let pieces = source.components(separatedBy: "::")
        guard pieces.count <= 2 else { throw LegacyLocatorError.invalidSyntax }
        let base = pieces[0]
        let pattern = #"^LLS-AOL:([0-9]+)(?:<([^<>]+)>)?\.([0-9]+)\.([0-9]+)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)), match.range.length == base.utf16.count {
            let text = base as NSString
            let label = match.range(at: 2).location == NSNotFound ? nil : text.substring(with: match.range(at: 2))
            guard label.map({ $0.utf16.count <= 260 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) ?? true else { throw LegacyLocatorError.invalidSyntax }
            return .init(articleID: try unsigned(text.substring(with: match.range(at: 1))), articleLabel: label,
                offset: try unsigned(text.substring(with: match.range(at: 3))), length: try unsigned(text.substring(with: match.range(at: 4))),
                relative: pieces.count == 2 ? try LegacyRelativeLocator.parse("::" + pieces[1]) : nil)
        }
        let simple: [String]
        if base.hasPrefix("LLS-AO:") { simple = String(base.dropFirst(7)).components(separatedBy: "."); guard simple.count == 2 else { throw LegacyLocatorError.invalidSyntax } }
        else if base.hasPrefix("LLS-A:") { simple = [String(base.dropFirst(6))] }
        else { throw LegacyLocatorError.invalidSyntax }
        return .init(articleID: try unsigned(simple[0]), articleLabel: nil, offset: simple.count == 2 ? try unsigned(simple[1]) : 0,
            length: 0, relative: pieces.count == 2 ? try LegacyRelativeLocator.parse("::" + pieces[1]) : nil)
    }
    static func unsigned(_ text: String) throws -> UInt32 {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw LegacyLocatorError.invalidSyntax }
        guard let value = UInt32(text) else { throw LegacyLocatorError.overflow }; return value
    }
    /// Verified arithmetic: an article delta resets offset/length; a nonzero
    /// length override replaces length, then the offset delta is applied.
    public func absoluteCoordinates(articleID resolvedArticle: UInt32? = nil) throws -> (articleID: UInt32, offset: UInt32, length: UInt32) {
        var article = resolvedArticle ?? articleID, offset = Int64(self.offset), length = self.length
        if let relative {
            if relative.articleDelta != 0 {
                let sum = article.addingReportingOverflow(relative.articleDelta)
                guard !sum.overflow else { throw LegacyLocatorError.overflow }
                article = sum.partialValue; offset = 0; length = 0
            }
            if relative.lengthOverride != 0 { length = relative.lengthOverride }
            let sum = offset.addingReportingOverflow(relative.offsetDelta)
            guard !sum.overflow else { throw LegacyLocatorError.overflow }
            offset = sum.partialValue
        }
        guard offset >= 0, offset <= Int64(UInt32.max) else { throw LegacyLocatorError.overflow }
        return (article, UInt32(offset), length)
    }
}

public struct LegacyCharacterCounts: Sendable, Equatable {
    public let cumulative: [UInt32]
    public func count(articleID: UInt32) throws -> UInt32 {
        guard Int(articleID) < cumulative.count else { throw LegacyLocatorError.outsideArticle }
        let previous = articleID == 0 ? 0 : cumulative[Int(articleID) - 1]
        return cumulative[Int(articleID)] - previous
    }
    public static func inspect(lsfURL: URL, lixURL: URL, articleCount: Int) throws -> LegacyCharacterCounts {
        let pair = try LegacyResourceReader.inspect(lsfURL: lsfURL, lixURL: lixURL)
        guard pair.identifiersMatch == true else { throw LegacyIndicesError.mismatchedPair }
        let blocks = pair.lix?.blocks.filter { $0.tag == "ccct" } ?? []
        guard blocks.count == 1, let block = blocks.first else { throw LegacyLocatorError.missingCharacterTable }
        guard articleCount >= 0, articleCount <= 500_000, block.length == UInt64(articleCount) * 4,
              block.length <= 2_000_000 else { throw LegacyLocatorError.characterTableMismatch }
        let stream = try FileHandle(forReadingFrom: lixURL); defer { try? stream.close() }
        try stream.seek(toOffset: block.offset - 8)
        guard let header = try stream.read(upToCount: 8), header.count == 8,
              String(decoding: header.prefix(4), as: UTF8.self) == "ccct" else { throw LegacyLocatorError.characterTableMismatch }
        func integer(_ data: Data, _ at: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[at + $1]) << ($1 * 8) } }
        guard integer(header, 4) == block.length,
              let data = try stream.read(upToCount: Int(block.length)), data.count == block.length else { throw LegacyLocatorError.characterTableMismatch }
        var values: [UInt32] = [], previous: UInt32 = 0
        for at in stride(from: 0, to: data.count, by: 4) {
            if at.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let value = integer(data, at); guard value >= previous else { throw LegacyLocatorError.characterTableMismatch }
            values.append(value); previous = value
        }
        return .init(cumulative: values)
    }
}
