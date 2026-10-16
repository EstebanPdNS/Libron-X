import Foundation

/// Read-only verse collection. Source order and boundaries are checked before
/// formatting; no canonical verse counts or generated text fill a missing span.
public actor BibleCopyService {
    private let content = LegacyContentService()
    public init() {}
    public func prepare(_ resource:LibraryResource, passage: BibleCopyPassage, abbreviation:String,
                        maximumArticles:Int = 256, maximumCharacters:Int = 4_000_000, includeFootnotes:Bool = true) async throws -> BibleCopyDocument {
        guard resource.format == .legacyLSF else { throw ReaderOutputError.unsupportedFormat }
        guard maximumArticles > 0, maximumArticles <= 4_096, maximumCharacters > 0,
              !abbreviation.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, abbreviation.utf8.count <= 256 else { throw BibleCopyError.limitExceeded }
        let file=resource.location, lix=resource.indexLocation ?? file.deletingPathExtension().appendingPathExtension("LIX")
        let before=try LegacyGraphicsService.fileStamp(file), indexBefore=try LegacyGraphicsService.fileStamp(lix)
        let pair=try LegacyResourceReader.inspect(lsfURL:file,lixURL:lix)
        guard pair.identifiersMatch == true, pair.lsf.bkidHex?.lowercased() == resource.legacyIdentifier?.lowercased() else { throw LegacyLocatorError.resourceMismatch }
        let index=try LegacyIndicesReader.inspect(lsfURL:file,lixURL:lix), typography=try LegacyTypographyReader.inspect(lsfURL:file)
        let directory=LegacyIndicesReader.articleDirectory(index:index)
        let markers=directory.entries.compactMap { entry -> Chapter? in
            guard entry.level > 0, let name=entry.positionLabel else { return nil };return Chapter(name,article:entry.sectionOrdinal)
        }
        func marker(_ address:BibleCopyAddress) throws -> Int? {
            let matches=Set(markers.filter{$0.key==address.bookKey && $0.number==address.chapter}.map(\.article))
            guard matches.count <= 1 else { throw ReaderOutputError.ambiguousChapter };return matches.first
        }
        let firstMarker=try marker(passage.start), lastMarker=try marker(passage.end)
        var sections:[LegacySectionContent] = [], lower:Int?, upper:Int?
        if let firstMarker, let lastMarker {
            guard firstMarker <= lastMarker else { throw BibleCopyError.reversedPassage }
            lower=firstMarker;upper=markers.filter{$0.article > lastMarker}.map(\.article).min() ?? index.sections.sections.count
        } else if !markers.isEmpty {
            // This resource has explicit checked chapter labels. Missing source
            // chapter is the citation-only case, not a budgeted failed search.
            guard passage.start == passage.end else { throw BibleCopyError.missingBoundary }
            return try empty(resource,passage:passage,abbreviation:abbreviation,typography:typography,metadata:pair.lsf,
                             file:file,lix:lix,before:before,indexBefore:indexBefore)
        } else {
            let first=try await content.resolvePassage(file,indexURL:lix,reference:passage.start.key,maximumCandidates:4_096)
            guard let start=first.match else {
                guard first.exhaustedCandidates, first.diagnostics.isEmpty else { throw BibleCopyError.incompleteSource }
                return try empty(resource,passage:passage,abbreviation:abbreviation,typography:typography,metadata:pair.lsf,
                                 file:file,lix:lix,before:before,indexBefore:indexBefore)
            }
            lower=start.sectionOrdinal
            if !passage.wholeChapter {
                let last=passage.start==passage.end ? first : try await content.resolvePassage(file,indexURL:lix,reference:passage.end.key,maximumCandidates:4_096)
                guard let end=last.match else { throw BibleCopyError.missingBoundary }
                guard start.sectionOrdinal <= end.sectionOrdinal else { throw BibleCopyError.reversedPassage };upper=end.sectionOrdinal+1
            }
        }
        guard let lower else { throw BibleCopyError.missingBoundary }
        if let upper { guard upper > lower else { throw BibleCopyError.missingBoundary } }
        let sourceEnd=upper ?? index.sections.sections.count
        let end=min(sourceEnd,lower+maximumArticles)
        var consumed=0, sawNextChapter=false, reachedRequestedEnd=false
        for ordinal in lower..<end {
            try Task.checkCancellation()
            let section=try await content.read(file,ordinal:ordinal)
            let nextChapter = upper == nil && section.anchors.contains(where:{ anchor in
                guard anchor.dataTypeCode==2,let reference=anchor.reference,let q=LegacyPassageQuery.parse(reference) else { return false }
                return q.sourceBookKey != passage.start.bookKey || q.chapter != passage.start.chapter
            })
            if nextChapter && !section.anchors.contains(where: { anchor in
                guard anchor.dataTypeCode==2,let reference=anchor.reference,let q=LegacyPassageQuery.parse(reference) else { return false }
                return q.sourceBookKey==passage.start.bookKey && q.chapter==passage.start.chapter
            }) { sawNextChapter=true;break }
            consumed += section.plainText.utf16.count
            guard consumed <= maximumCharacters else { throw BibleCopyError.limitExceeded }
            sections.append(section)
            // Chapter labels bound the search, rather than requiring the whole
            // chapter for a single verse. Later articles need not be decoded or
            // charged against this request once its end is present in source.
            if !passage.wholeChapter && section.anchors.contains(where:{ anchor in
                guard anchor.dataTypeCode==2,let reference=anchor.reference else { return false }
                return LegacyPassageQuery.parse(reference).map{BibleCopyAddress($0)==passage.end} == true
            }) { reachedRequestedEnd=true;break }
            if nextChapter { sawNextChapter=true;break }
        }
        if !reachedRequestedEnd && !sawNextChapter && end != sourceEnd { throw BibleCopyError.limitExceeded }
        var observed:[LocatedVerse] = []
        for section in sections {
            let anchors=section.anchors.filter{$0.dataTypeCode==2 && $0.reference.flatMap(LegacyPassageQuery.parse) != nil}
            for anchor in anchors {
                guard let reference=anchor.reference,let query=LegacyPassageQuery.parse(reference) else { continue }
                let address=BibleCopyAddress(query)
                if let previous=observed.last,previous.address==address {
                    guard previous.section.descriptor.ordinal==section.descriptor.ordinal else { throw BibleCopyError.incompleteSource }
                    // BHS binds both a heading and its first verse to Ge 1:1.
                    // The later body anchor must be followed by its number run.
                    guard followsNumber(anchor.characterOffset,address:address,section:section,typography:typography) else { throw BibleCopyError.incompleteSource }
                    observed[observed.count-1] = .init(address:address,reference:reference,start:anchor.characterOffset,section:section)
                } else { observed.append(.init(address:address,reference:reference,start:anchor.characterOffset,section:section)) }
            }
        }
        guard let first=observed.firstIndex(where:{$0.address==passage.start}) else {
            return try empty(resource,passage:passage,abbreviation:abbreviation,typography:typography,metadata:pair.lsf,
                             file:file,lix:lix,before:before,indexBefore:indexBefore)
        }
        let last:Int
        if passage.wholeChapter {
            guard let found=observed.lastIndex(where:{$0.address.bookKey==passage.start.bookKey && $0.address.chapter==passage.start.chapter}) else { throw BibleCopyError.missingBoundary };last=found
        } else {
            guard let found=observed.lastIndex(where:{$0.address==passage.end}) else { throw BibleCopyError.missingBoundary };last=found
        }
        guard first <= last else { throw BibleCopyError.reversedPassage }
        let chosen=Array(observed[first...last]);try checkSequence(chosen)
        var verses:[BibleCopyVerse]=[],sources:[ReaderOutputSource]=[],notes:[BibleCopyFootnote]=[]
        var bounds:[Int:SearchTextRange]=[:]
        for (offset,item) in chosen.enumerated() {
            try Task.checkCancellation()
            let section=item.section,ordinal=section.descriptor.ordinal
            let next=observed.first(where:{$0.section.descriptor.ordinal==ordinal && $0.start > item.start})?.start ?? section.plainText.utf16.count
            let positions=index.referencePositions.filter{Int($0.startArticleID)==ordinal && Int($0.startCharacterOffset)==item.start}
            guard positions.count <= 1 else { throw BibleCopyError.missingBoundary }
            let end:Int
            if let position=positions.first {
                guard position.endArticleID==position.startArticleID else { throw BibleCopyError.missingBoundary }
                end=Int(position.endCharacterOffset)+1
            } else { end=next }
            guard end > item.start, end <= next, end <= section.plainText.utf16.count else { throw BibleCopyError.missingBoundary }
            let range=SearchTextRange(location:item.start,length:end-item.start)
            try compatible(section,range:range)
            let original = section.plainText as NSString
            guard Range(range.nsRange,in:section.plainText) != nil,
                  [range.location,range.upperBound].allSatisfy({ $0==original.length || original.rangeOfComposedCharacterSequence(at:$0).location==$0 }) else {
                throw BibleCopyError.incompleteSource
            }
            let source=ReaderOutputSource(sectionOrdinal:ordinal,decodedTextSHA256:LibrarySearchService.textFingerprint(section.plainText),selectedRange:range)
            let paragraph=section.paragraphs.last(where:{$0.characterOffset <= item.start})
            guard let paragraph, paragraph.kind == .text,paragraph.label == nil else { throw BibleCopyError.unsupportedContent }
            var fragments:[BibleCopyFragment]=[]
            for run in section.runs {
                let start=max(item.start,run.characterOffset), finish=min(end,run.characterOffset+run.logicalCharacterCount)
                guard start < finish else { continue }
                guard let style=typography.characterStyle(run.styleIdentifier) else { throw LegacyTypographyError.invalidTable }
                let text=(section.plainText as NSString).substring(with:NSRange(location:start,length:finish-start))
                let footnote=(run.sourceRunFlags & 3)==3 ? run.attribute : nil
                fragments.append(.init(text:text,style:style,sourceRange:.init(location:start,length:finish-start),footnote:footnote,
                                       isBibleText:run.sourceRunFlags & 0x8000 != 0,isVerseNumber:style.isSuperscript &&
                                       text.unicodeScalars.filter{!CharacterSet.whitespacesAndNewlines.contains($0) && $0.value != 0x200b}.allSatisfy{CharacterSet.decimalDigits.contains($0)}))
                if includeFootnotes,let footnote,!notes.contains(where:{$0.id==footnote}) {
                    let positions=index.namedPositions.filter{$0.label==footnote}
                    guard positions.count==1,let destination=positions.first else { throw BibleCopyError.missingBoundary }
                    let note=try await content.read(file,ordinal:Int(destination.articleID))
                    guard note.tables.isEmpty,note.graphics.isEmpty,note.markers.isEmpty,note.plainText.utf16.count <= maximumCharacters-consumed else { throw BibleCopyError.unsupportedContent }
                    consumed += note.plainText.utf16.count
                    notes.append(.init(id:footnote,marker:run.text,text:note.plainText,
                        source:.init(sectionOrdinal:note.descriptor.ordinal,decodedTextSHA256:LibrarySearchService.textFingerprint(note.plainText),selectedRange:.init(location:0,length:note.plainText.utf16.count))))
                }
            }
            guard fragments.contains(where:{$0.isBibleText}) else { throw BibleCopyError.incompleteSource }
            verses.append(.init(address:item.address,sourceReference:item.reference,source:source,paragraphKey:"\(ordinal):\(paragraph.characterOffset)",
                                paragraphStyle:typography.paragraphStyle(paragraph.styleIdentifier),fragments:fragments));sources.append(source)
            let prior=bounds[ordinal];let start=min(prior?.location ?? range.location,range.location),finish=max(prior?.upperBound ?? range.upperBound,range.upperBound)
            bounds[ordinal] = .init(location:start,length:finish-start)
            if offset > 0 && chosen[offset-1].section.descriptor.ordinal < ordinal {
                for gap in (chosen[offset-1].section.descriptor.ordinal+1)..<ordinal where bounds[gap]==nil {
                    guard let gapSection=sections.first(where:{$0.descriptor.ordinal==gap}) else { throw BibleCopyError.incompleteSource }
                    bounds[gap] = .init(location:0,length:gapSection.plainText.utf16.count)
                }
            }
        }
        var full:[ReaderOutputParagraph]=[],sourceParagraphs:[BibleCopySourceParagraph]=[]
        for section in sections {
            guard let bound=bounds[section.descriptor.ordinal] else { continue }
            try compatible(section,range:bound)
            for paragraph in section.paragraphs {
                let start=max(bound.location,paragraph.characterOffset),end=min(bound.upperBound,paragraph.characterOffset+paragraph.text.utf16.count)
                guard start < end else { continue }
                guard paragraph.kind == .text,paragraph.label==nil,let pstyle=typography.paragraphStyle(paragraph.styleIdentifier) else { throw BibleCopyError.unsupportedContent }
                var spans:[ReaderOutputSpan]=[],fragments:[BibleCopyFragment]=[]
                for run in section.runs {
                    let lo=max(start,run.characterOffset),hi=min(end,run.characterOffset+run.logicalCharacterCount)
                    if lo < hi {
                        guard let cstyle=typography.characterStyle(run.styleIdentifier) else { throw LegacyTypographyError.invalidTable }
                        spans.append(.init(range:.init(location:lo-start,length:hi-lo),style:cstyle))
                        let text=(section.plainText as NSString).substring(with:NSRange(location:lo,length:hi-lo))
                        fragments.append(.init(text:text,style:cstyle,sourceRange:.init(location:lo,length:hi-lo),
                            footnote:(run.sourceRunFlags & 3)==3 ? run.attribute:nil,isBibleText:run.sourceRunFlags & 0x8000 != 0,
                            isVerseNumber:cstyle.isSuperscript && text.unicodeScalars.filter{!CharacterSet.whitespacesAndNewlines.contains($0) && $0.value != 0x200b}.allSatisfy{CharacterSet.decimalDigits.contains($0)}))
                    }
                }
                full.append(.init(text:(section.plainText as NSString).substring(with:NSRange(location:start,length:end-start)),style:pstyle,spans:spans))
                let marks=chosen.filter{$0.section.descriptor.ordinal==section.descriptor.ordinal && $0.start>=start && $0.start<end}
                    .map{BibleCopySourceMark(offset:$0.start,address:$0.address)}
                sourceParagraphs.append(.init(style:pstyle,fragments:fragments,marks:marks))
            }
        }
        try stable(file,lix:lix,before:before,indexBefore:indexBefore)
        var result=BibleCopyDocument(resourceID:resource.id,passage:passage,title:resource.title,abbreviation:abbreviation,verses:verses,footnotes:notes,
                     citation:ReaderBibliographicCitation.text(pair.lsf,title:resource.title),typography:typography,sources:sources,fullParagraphs:full,sourceLanguages:pair.lsf.declaredLanguages)
        result.sourceParagraphs=sourceParagraphs;return result
    }
    private struct LocatedVerse {
        let address:BibleCopyAddress;let reference:String;let start:Int;let section:LegacySectionContent
    }
    private func compatible(_ section:LegacySectionContent,range:SearchTextRange) throws {
        func touches(_ start:Int,_ length:Int) -> Bool { start < range.upperBound && (length==0 ? start>=range.location:start+length>range.location) }
        guard !section.tables.contains(where:{touches($0.characterOffset,$0.characterCount)}),
              !section.graphics.contains(where:{touches($0.characterOffset,$0.characterWidth)}),
              !section.markers.contains(where:{touches($0.characterOffset,$0.characterWidth)}) else { throw BibleCopyError.unsupportedContent }
    }
    private struct Chapter {
        let key:String;let number:Int;let article:Int
        init?(_ text:String,article:Int) {
            let parts=text.components(separatedBy:".CH")
            guard parts.count==2,let number=Int(parts[1]),number>0,String(number)==parts[1],
                  let q=LegacyPassageQuery.parse("\(parts[0]) \(number):1") else { return nil }
            key=q.sourceBookKey;self.number=number;self.article=article
        }
    }
    private func followsNumber(_ offset:Int,address:BibleCopyAddress,section:LegacySectionContent,typography:LegacyTypography) -> Bool {
        section.runs.contains { run in
            run.characterOffset >= offset && run.characterOffset-offset <= 8 && typography.characterStyle(run.styleIdentifier)?.isSuperscript == true &&
            run.text.unicodeScalars.filter{CharacterSet.decimalDigits.contains($0)}.map{String($0)}.joined()==String(address.verse)
        }
    }
    private func checkSequence(_ verses:[LocatedVerse]) throws {
        for pair in zip(verses,verses.dropFirst()) {
            let a=pair.0.address,b=pair.1.address
            if a.bookKey==b.bookKey && a.chapter==b.chapter {
                guard b.verse==a.verse+1 else { throw BibleCopyError.incompleteSource }
            } else if a.bookKey==b.bookKey {
                guard b.chapter==a.chapter+1,b.verse==1 else { throw BibleCopyError.incompleteSource }
            } else { guard b.chapter==1,b.verse==1 else { throw BibleCopyError.incompleteSource } }
        }
    }
    private func stable(_ file:URL,lix:URL,before:LegacyGraphicSourceStamp,indexBefore:LegacyGraphicSourceStamp) throws {
        try Task.checkCancellation()
        guard try LegacyGraphicsService.fileStamp(file)==before,try LegacyGraphicsService.fileStamp(lix)==indexBefore else { throw LegacyIndicesError.sourceChanged }
    }
    private func empty(_ resource:LibraryResource,passage:BibleCopyPassage,abbreviation:String,typography:LegacyTypography,metadata:LegacyMetadata,
                       file:URL,lix:URL,before:LegacyGraphicSourceStamp,indexBefore:LegacyGraphicSourceStamp) throws -> BibleCopyDocument {
        try stable(file,lix:lix,before:before,indexBefore:indexBefore)
        return .init(resourceID:resource.id,passage:passage,title:resource.title,abbreviation:abbreviation,verses:[],footnotes:[],
                     citation:ReaderBibliographicCitation.text(metadata,title:resource.title),typography:typography,sources:[],fullParagraphs:[],sourceLanguages:metadata.declaredLanguages)
    }
}

public enum ReaderBibliographicCitation {
    public static func text(_ metadata:LegacyMetadata,title:String) -> String {
        let parts=(metadata.publication ?? "").components(separatedBy:" | ").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}
        func clean(_ value:String) -> String { value.trimmingCharacters(in:CharacterSet(charactersIn:" :,;.")) }
        if parts.count==3 { return "\(title). \(clean(parts[2])). \(clean(parts[0])): \(clean(parts[1]))." }
        let publication=metadata.publication.map(clean).flatMap{$0.isEmpty ? nil : $0}
        return title+"."+(publication.map{" "+$0+"."} ?? "")
    }
}
