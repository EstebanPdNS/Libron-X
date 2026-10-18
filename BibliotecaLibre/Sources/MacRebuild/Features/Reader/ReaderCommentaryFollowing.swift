import Foundation
import LibronixCore

@MainActor extension StudyWorkspace {
    func setCommentaryFollowing(_ enabled: Bool, for reader: ReaderSession) {
        reader.followsCommentary = enabled
        if !enabled { reader.cancel(); reader.pendingCommentaryOrdinal = nil }
        else if let source = readers.first(where: { $0.id == reader.commentarySourceID }),
                let reference = source.currentReference {
            updateCommentaryFollowers(from: source, reference: reference)
        }
    }
    /// Follow only explicit commentary links owned by this verse and edition.
    /// No footnote, ordinal proximity or citation label is used to invent a match.
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
            guard let ordinal = link?.sectionOrdinal else {
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
