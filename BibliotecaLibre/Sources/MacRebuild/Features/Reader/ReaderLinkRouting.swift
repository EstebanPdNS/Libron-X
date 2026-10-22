import Foundation
import LibronixCore

@MainActor extension StudyWorkspace {
    func resourceForInlineLink(_ link: LegacyInlineLink, source: LibraryResource) throws -> LibraryResource {
        guard case let .bible(reference) = link.target else { return source }
        let target = readers.first { $0.id == referenceTargetID && $0.hasObservedBible }
        if let edition = reference.edition {
            func matches(_ resource: LibraryResource) -> Bool {
                ReaderSession.matchesEdition(resource, edition)
            }
            if let target, matches(target.resource) { return target.resource }
            if matches(source) { return source }
            let candidates = availableResources.filter(matches)
            guard candidates.count == 1, let resource = candidates.first else { throw RebuildError.referenceEditionUnavailable(edition) }
            return resource
        }
        if let target { return target.resource }
        let scope = KeyLinkScope(kind: .bible)
        let preferred = resourcePriorities.ordered(availableResources, in: scope)
        if let chosen = preferred.first(where: { resourcePriorities.rank($0, in: scope) != nil }) { return chosen }
        if readers.contains(where: { $0.resource.id == source.id && $0.hasObservedBible }) { return source }
        if let bible = presentedReaders.first(where: \.hasObservedBible) { return bible.resource }
        if let bible = preferred.first { return bible }
        throw RebuildError.bibleReferenceTargetUnavailable
    }
    func openInlineLink(_ resource: LibraryResource, destination: ReaderDestination, from source: ReaderSession, newReader: Bool) {
        if newReader {
            var resolvedDestination = destination
            let owner = source.commentarySourceID.flatMap { id in readers.first { $0.id == id } } ?? source
            let isNote = destination.reference == nil && resource.id == owner.resource.id &&
                (owner.canSynchronizeBible || source.isCommentary)
            let target: ReaderSession
            let created: Bool
            if isNote, let existing = readers.first(where: {
                $0 !== owner && $0.resource.id == resource.id && ($0.isCommentary ||
                    (!$0.canSynchronizeBible && $0.page?.destination.ordinal == destination.ordinal))
            }) {
                target = existing; created = false; activate(target)
            } else { target = open(resource, startReading: false); created = true }
            if isNote {
                target.commentarySourceID = owner.isCommentary ? nil : owner.id
                target.commentaryResourceID = resource.id
                target.followsCommentary = true
                let context = owner.readingFlowPages.first { page in
                    page.inlineLinks.contains { $0.sectionOrdinal == destination.ordinal }
                }
                let link = context?.inlineLinks.first { $0.sectionOrdinal == destination.ordinal }
                let index = ReaderBibleIndex(anchors: context?.content?.anchors ?? [], textLength: context?.text.utf16.count)
                target.commentaryReference = link.flatMap { index.reference(at: $0.range.location) } ?? owner.currentReference
                target.pendingCommentaryOrdinal = destination.ordinal
                target.pendingCommentaryChapter = nil
                if link?.role == .studyCommentary, LibronNativeReader.location(resource) != nil,
                   let reference = target.commentaryReference,
                   let query = LegacyPassageQuery.sourceReference(reference) {
                    let chapter = "\(query.sourceBookKey) \(query.chapter):1"
                    target.pendingCommentaryChapter = chapter
                    resolvedDestination = .init(ordinal: context?.destination.ordinal ?? 0, reference: reference, commentaryChapter: chapter)
                }
                if created { target.frame = PaneFrame(x: 0.45, y: 0.04, width: 0.54, height: 0.91) }
            }
            target.rememberCommentaryLocation()
            target.load(resolvedDestination, propagateReference: false)
            return
        }
        let explicit = destination.reference == nil ? nil : readers.first { $0.id == referenceTargetID && $0.resource.id == resource.id }
        let target = explicit ?? (source.resource.id == resource.id ? source : readers.first { $0.resource.id == resource.id })
            ?? open(resource, startReading: false)
        activate(target); target.rememberCommentaryLocation(); target.load(destination)
    }
}
