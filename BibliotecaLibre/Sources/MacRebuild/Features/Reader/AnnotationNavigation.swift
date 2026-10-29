import Foundation
import LibronixCore

struct ReaderAnnotationDestination: Equatable {
    let ordinal: Int
    let range: NSRange
    let fingerprint: String
    let stableID: String
}

@MainActor extension StudyWorkspace {
    func annotationDestinations(for reader: ReaderSession) -> [ReaderAnnotationDestination] {
        let highlights = personal.highlights.filter { $0.resourceID == reader.resource.id }.map {
            ReaderAnnotationDestination(ordinal: $0.ordinal, range: $0.range, fingerprint: $0.fingerprint, stableID: "h:" + $0.id.uuidString)
        }
        let notes = personal.noteLinks(for: reader.resource).map {
            ReaderAnnotationDestination(ordinal: $0.ordinal, range: $0.range, fingerprint: $0.fingerprint, stableID: "n:" + $0.documentID.uuidString + ":" + $0.noteID.uuidString)
        }
        return (highlights + notes).filter { $0.ordinal >= 0 && $0.range.location >= 0 && $0.range.length > 0 }
            .sorted {
                if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
                if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
                return $0.stableID < $1.stableID
            }
    }
    func adjacentAnnotation(for reader: ReaderSession, backwards: Bool) -> ReaderAnnotationDestination? {
        guard !reader.isLoading, let page = reader.page, page.oeb == nil else { return nil }
        let ordinal = page.destination.ordinal, offset = reader.selectedRange.location
        let all = annotationDestinations(for: reader)
        if backwards { return all.last { $0.ordinal < ordinal || ($0.ordinal == ordinal && $0.range.location < offset) } }
        return all.first { $0.ordinal > ordinal || ($0.ordinal == ordinal && ($0.range.location > offset || ($0.range.location == offset && reader.selectedRange.length == 0))) }
    }
    func navigateAnnotation(backwards: Bool) {
        guard let reader = activeReader, let destination = adjacentAnnotation(for: reader, backwards: backwards) else { return }
        reader.load(.init(ordinal: destination.ordinal), selection: destination.range, expectedFingerprint: destination.fingerprint)
    }
}
