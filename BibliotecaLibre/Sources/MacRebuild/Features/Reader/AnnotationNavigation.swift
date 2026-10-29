import Foundation
import LibronixCore

struct ReaderAnnotationDestination: Equatable {
    let ordinal: Int
    let range: NSRange
    let fingerprint: String
    let stableID: String
}
struct ReaderAnnotationCursor {
    let readerID: UUID
    let destination: ReaderAnnotationDestination
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
        guard !reader.isLoading, let page = reader.page, page.oeb == nil || reader.oebProjectionReady else { return nil }
        let ordinal = page.destination.ordinal, offset = reader.selectedRange.location
        let all = annotationDestinations(for: reader)
        if let cursor = annotationNavigationCursor, cursor.readerID == reader.id,
           cursor.destination.ordinal == ordinal, cursor.destination.range == reader.selectedRange,
           let index = all.firstIndex(of: cursor.destination) {
            let target = index + (backwards ? -1 : 1)
            return all.indices.contains(target) ? all[target] : nil
        }
        if backwards { return all.last { $0.ordinal < ordinal || ($0.ordinal == ordinal && $0.range.location < offset) } }
        return all.first { $0.ordinal > ordinal || ($0.ordinal == ordinal && ($0.range.location > offset || ($0.range.location == offset && reader.selectedRange.length == 0))) }
    }
    func navigateAnnotation(backwards: Bool) {
        guard let reader = activeReader, let destination = adjacentAnnotation(for: reader, backwards: backwards) else { return }
        annotationNavigationCursor = .init(readerID: reader.id, destination: destination)
        if reader.page?.oeb != nil { reader.navigateOEBAnnotation(destination) }
        else { reader.load(.init(ordinal: destination.ordinal), selection: destination.range, expectedFingerprint: destination.fingerprint) }
    }
}
