import Foundation
import LibronixCore

@MainActor extension StudyWorkspace {
    func setCommentaryFollowing(_ enabled: Bool, for reader: ReaderSession) {
        reader.followsCommentary = enabled
        if !enabled { reader.cancel(); reader.pendingCommentaryOrdinal = nil; reader.pendingCommentaryChapter = nil }
        else if let source = readers.first(where: { $0.id == reader.commentarySourceID }),
                let reference = source.commentaryViewportReference ?? source.currentReference {
            updateCommentaryFollowers(from: source, reference: reference)
        }
    }
    /// Follow explicit verse links and verified note-heading ranges in this edition.
    func updateCommentaryFollowers(from source: ReaderSession, reference: String) {
        guard readers.contains(where: { $0 === source }),
              let key = LegacyPassageQuery.sourceReference(reference)?.normalizedKey else { return }
        for target in readers where target.commentarySourceID == source.id && target.commentaryResourceID != source.resource.id {
            target.commentarySourceID = nil
        }
        let followers = readers.filter {
            $0.commentarySourceID == source.id && $0.followsCommentary &&
            $0.commentaryResourceID == source.resource.id && $0.resource.id == source.resource.id
        }
        guard !followers.isEmpty else { return }
        let link = source.page?.inlineLinks.first {
            $0.role == .studyCommentary && $0.sectionOrdinal != nil &&
            source.bibleReference(at: $0.range.location).flatMap(LegacyPassageQuery.sourceReference)?.normalizedKey == key
        }
        for target in followers {
            if let restored = target.commentaryRestoreReference {
                target.commentaryRestoreReference = nil
                if restored == reference { continue }
            }
            target.commentaryReference = reference
            if LibronNativeReader.location(source.resource) != nil,
               let query = LegacyPassageQuery.sourceReference(reference) {
                let chapter = "\(query.sourceBookKey) \(query.chapter):1"
                if target.page?.destination.commentaryChapter == chapter, !target.isLoading {
                    target.alignCommentary(to: reference); continue
                }
                if target.pendingCommentaryChapter == chapter && target.isLoading { continue }
                target.pendingCommentaryChapter = chapter
                target.load(.init(ordinal: source.page?.destination.ordinal ?? 0, reference: reference, commentaryChapter: chapter),
                    propagateReference: false, recordHistory: false)
                continue
            }
            guard let ordinal = link?.sectionOrdinal ?? source.page?.commentaryOrdinals[key] else {
                target.cancel(); target.pendingCommentaryOrdinal = nil
                target.page = nil; target.flowPages = []; target.visibleBibleReference = nil
                target.locator = reference
                target.error = nil
                continue
            }
            if target.pendingCommentaryOrdinal == ordinal && (target.isLoading || target.page?.destination.ordinal == ordinal) { continue }
            target.pendingCommentaryOrdinal = ordinal
            target.page = nil; target.flowPages = []
            target.load(.init(ordinal: ordinal), propagateReference: false, recordHistory: false)
        }
    }
}
