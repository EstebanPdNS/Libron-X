import Foundation
import LibronixCore

/// A passage part retains a complete, unchanged physical article. Its selected
/// interval always belongs to that article's own UTF-16 text, not a flattened
/// range shared with a different article or edition.
struct ReaderPassagePart: Sendable {
    let content: LegacySectionContent
    let selection: NSRange
    let reference: String
    var graphics: [LegacyGraphicAsset] = []
    var ordinal: Int { content.descriptor.ordinal }
}

struct ReaderPassagePartSource {
    static func read(_ url: URL, service: LegacyContentService, start: LegacyReferenceMatch,
                     end: LegacyReferenceMatch) async throws -> [ReaderPassagePart] {
        guard start.sectionOrdinal <= end.sectionOrdinal,
              end.sectionOrdinal - start.sectionOrdinal < 256 else { throw RebuildError.passageReadLimit }
        var parts: [ReaderPassagePart] = [], totalUnits = 0
        for ordinal in start.sectionOrdinal...end.sectionOrdinal {
            try Task.checkCancellation()
            let content = try await service.read(url, ordinal: ordinal)
            totalUnits += content.plainText.utf16.count
            guard totalUnits <= 8 * 1_024 * 1_024 else { throw RebuildError.passageReadLimit }
            let begin = ordinal == start.sectionOrdinal ? start.startCharacterOffset : 0
            let finish = ordinal == end.sectionOrdinal ? end.endCharacterOffsetExclusive : content.plainText.utf16.count
            let reference: String?
            if ordinal == start.sectionOrdinal {
                reference = start.observedReference
            } else {
                reference = content.anchors.compactMap { anchor -> String? in
                    anchor.reference.flatMap { LegacyPassageQuery.sourceReference($0)?.displayReference }
                }.first
            }
            parts.append(try validatedPart(content: content, start: begin, end: finish, reference: reference))
        }
        return parts
    }
    static func validatedPart(content: LegacySectionContent, start: Int, end: Int, reference: String?) throws -> ReaderPassagePart {
        let source = content.plainText as NSString
        func isScalarBoundary(_ position: Int) -> Bool {
            guard position > 0, position < source.length else { return true }
            return !((0xDC00...0xDFFF).contains(source.character(at: position)) &&
                     (0xD800...0xDBFF).contains(source.character(at: position - 1)))
        }
        guard content.hasCompatibleFlatTextProjection, start >= 0, end > start, end <= content.plainText.utf16.count,
              isScalarBoundary(start), isScalarBoundary(end),
              let reference, let query = LegacyPassageQuery.sourceReference(reference),
              Range(NSRange(location: start, length: end - start), in: content.plainText) != nil else {
            throw RebuildError.invalidPassagePart
        }
        return .init(content: content, selection: NSRange(location: start, length: end - start), reference: query.displayReference)
    }
}

extension ReaderPage {
    var passagePartIndex: Int? { passageParts.firstIndex { $0.ordinal == destination.ordinal } }
    func passageDestination(at index: Int) -> ReaderDestination? {
        guard passageParts.indices.contains(index) else { return nil }
        var result = destination
        result.ordinal = passageParts[index].ordinal
        result.reference = passageParts[index].reference
        result.prefersContentsStart = nil
        return result
    }
    var articlePositionLabel: String {
        let article = "Artículo \(destination.ordinal + 1) de \(sectionCount)"
        guard passageParts.count > 1, let index = passagePartIndex else { return article }
        return "Parte \(index + 1) de \(passageParts.count) · " + article
    }
    func articlePositionLabel(language: AppLanguage) -> String {
        let article = AppStrings.format("Artículo {current} de {total}", language: language,
            values: ["current": String(destination.ordinal + 1), "total": String(sectionCount)])
        guard passageParts.count > 1, let index = passagePartIndex else { return article }
        return AppStrings.format("Parte {current} de {total}", language: language,
            values: ["current": String(index + 1), "total": String(passageParts.count)]) + " · " + article
    }
}

extension ReaderDestination {
    func validate() throws {
        guard ordinal >= 0, passageStartReference == nil || endReference != nil else { throw RebuildError.invalidPassagePart }
        if let commentaryChapter {
            guard let chapter = LegacyPassageQuery.sourceReference(commentaryChapter), chapter.verse == 1,
                  endReference == nil else { throw RebuildError.invalidPassagePart }
        }
        if let endReference {
            guard let reference, LegacyPassageQuery.sourceReference(reference) != nil,
                  LegacyPassageQuery.sourceReference(endReference) != nil,
                  passageStartReference.map({ LegacyPassageQuery.sourceReference($0) != nil }) ?? true else { throw RebuildError.invalidPassagePart }
        }
        if let requiredEdition {
            guard !requiredEdition.isEmpty, requiredEdition.utf16.count <= 64,
                  requiredEdition.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }) else { throw RebuildError.invalidPassagePart }
        }
    }
}
