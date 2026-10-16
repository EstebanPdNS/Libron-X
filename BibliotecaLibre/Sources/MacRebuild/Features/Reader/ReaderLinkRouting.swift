import Foundation
import LibronixCore

@MainActor extension StudyWorkspace {
    func resourceForInlineLink(_ link: LegacyInlineLink, source: LibraryResource) throws -> LibraryResource {
        guard case let .bible(reference) = link.target else { return source }
        let target = readers.first { $0.id == referenceTargetID && $0.hasObservedBible }
        if let edition = reference.edition {
            func matches(_ resource: LibraryResource) -> Bool {
                resource.location.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(edition) == .orderedSame
            }
            if let target, matches(target.resource) { return target.resource }
            if matches(source) { return source }
            let candidates = availableResources.filter(matches)
            guard candidates.count == 1, let resource = candidates.first else { throw RebuildError.referenceEditionUnavailable(edition) }
            return resource
        }
        if let target { return target.resource }
        if readers.contains(where: { $0.resource.id == source.id && $0.hasObservedBible }) { return source }
        if let bible = presentedReaders.first(where: \.hasObservedBible) { return bible.resource }
        throw RebuildError.bibleReferenceTargetUnavailable
    }
    func openInlineLink(_ resource: LibraryResource, destination: ReaderDestination, from source: ReaderSession, newReader: Bool) {
        if newReader { open(resource, destination: destination); return }
        let explicit = destination.reference == nil ? nil : readers.first { $0.id == referenceTargetID && $0.resource.id == resource.id }
        let target = explicit ?? (source.resource.id == resource.id ? source : readers.first { $0.resource.id == resource.id })
            ?? open(resource, startReading: false)
        activate(target); target.load(destination)
    }
}
