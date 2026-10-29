import Foundation

/// Version zero is a derived output style, not a decoded legacy table record.
/// These adapters reuse the renderer's portable traits without claiming that
/// native HTML/RTF contained LOGFONT or original legacy style identifiers.
public extension LegacyTypography {
    static let importedOutput = LegacyTypography(version: 0, fontGroupVersion: 0, fontGroups: [], characterStyles: [], paragraphStyles: [], opaqueTail: Data())
}
public extension LegacyCharacterStyle {
    static func importedOutput(bold: Bool, italic: Bool, underline: Bool, strikeout: Bool,
                               superscript: Bool, subscriptText: Bool, color: UInt32?) -> Self {
        .init(id: 0, version: 0, flags: (superscript ? 1 : 0) | (subscriptText ? 2 : 0) | (color == nil ? 0 : 0x40),
            color: color ?? 0, backgroundColor: nil, locale: 0, sourceField: 0, extraField: nil, extraValue: nil,
            font: .init(values: [0,0,0,0,bold ? 700 : 400], attributes: [italic ? 1 : 0,underline ? 1 : 0,strikeout ? 1 : 0], family: "", rawFamily: Data()), alternateFont: nil)
    }
}
public extension LegacyTabStop {
    static func importedOutput(position: Int16, rightAligned: Bool) -> Self { .init(version: 0, kind: rightAligned ? 2 : 1, position: position) }
}
public extension LegacyParagraphStyle {
    static func importedOutput(alignment: LegacyTextAlignment?, rightToLeft: Bool,
                               headIndent: Int16, tailIndent: Int16, firstLineIndent: Int16,
                               spaceBefore: Int16, spaceAfter: Int16, tabs: [LegacyTabStop]) -> Self {
        let align: UInt16 = switch alignment { case .left: 4; case .right: 8; case .center: 0x10; case .justified: 0x20; case nil: 0 }
        return .init(version: 0, borders: [], firstValue: 0, secondValue: 0,
            fields: [0,0,UInt16(bitPattern: headIndent),UInt16(bitPattern: tailIndent),UInt16(bitPattern: firstLineIndent),
                     UInt16(bitPattern: spaceBefore),UInt16(bitPattern: spaceAfter),0,0], name: "", extraLineHeight: nil,
            flags: align | (rightToLeft ? 2 : 0), tabStops: tabs)
    }
}
