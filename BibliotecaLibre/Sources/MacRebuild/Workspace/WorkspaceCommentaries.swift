import Foundation
import LibronixCore

@MainActor extension StudyWorkspace {
    var commentaryResources: [LibraryResource] {
        availableResources.filter { LibronMetadata.deriving($0).resourceType == "Comentario bíblico" && LibronNativeReader.location($0) != nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func openCommentary(_ resource: LibraryResource? = nil, replacing reader: ReaderSession? = nil) {
        guard let resource = resource ?? commentaryResources.first else { return }
        let source = reader?.commentarySourceID.flatMap { id in readers.first { $0.id == id } }
            ?? activeReader.flatMap { $0.canSynchronizeBible ? $0 : nil } ?? bibleReaders.last
        let target: ReaderSession
        if let reader { target = reader; target.replaceCommentaryResource(resource) }
        else { target = open(resource, startReading: false) }
        target.commentaryResourceID = resource.id; target.commentaryFollowsActiveBible = reader?.commentaryFollowsActiveBible ?? true
        target.commentarySourceID = source?.id; target.followsCommentary = true
        if let source, let reference = source.currentReference { updateCommentaryFollowers(from: source, reference: reference) }
        else { target.load(.init(ordinal: 0)) }
        activate(target)
    }
    func chooseCommentarySource(_ source: ReaderSession?, for target: ReaderSession, activeBible: Bool) {
        let source = activeBible ? bibleReaders.last : source
        target.commentaryFollowsActiveBible = activeBible
        target.commentarySourceID = source?.id; target.followsCommentary = true
        if let source, let reference = source.currentReference { updateCommentaryFollowers(from: source, reference: reference) }
    }
}

