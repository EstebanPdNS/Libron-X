import Foundation
import LibronixCore

enum SermonArchiveOrder: String, CaseIterable, Sendable { case newest, oldest, title, speaker }
struct SermonArchiveSearchReport: Sendable {
    var documents: [StudyDocument] = []
    var incompleteDocuments = 0
}
enum SermonArchiveSearch {
    static func search(_ query: String, documents: [StudyDocument], order: SermonArchiveOrder) throws -> SermonArchiveSearchReport {
        guard query.utf16.count <= 512, !query.contains("\0") else { throw PersonalStateError.invalid("El texto supera el límite permitido.") }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var report = SermonArchiveSearchReport()
        for document in documents where document.kind == .sermon {
            try Task.checkCancellation()
            let metadata = document.sermon!
            let fields = [document.title, metadata.speaker, metadata.series, metadata.venue, metadata.dateText] + metadata.passages + metadata.tags
            if needle.isEmpty || fields.contains(where: { $0.localizedStandardContains(needle) }) {
                report.documents.append(document); continue
            }
            var found = false, incomplete = false
            for note in document.notes {
                try Task.checkCancellation()
                if note.title.localizedStandardContains(needle) || PersonalReferenceProjection.anchor(note)?.localizedStandardContains(needle) == true {
                    found = true; break
                }
                let projection = PersonalReferenceProjection.body(note)
                incomplete = incomplete || projection.issue != nil
                if projection.text.localizedStandardContains(needle) { found = true; break }
            }
            if found { report.documents.append(document) }
            if incomplete { report.incompleteDocuments += 1 }
        }
        report.documents.sort { a, b in
            switch order {
            case .newest, .oldest:
                let left = a.sermon!.preachedOn, right = b.sermon!.preachedOn
                if left != right {
                    guard let left else { return false }
                    guard let right else { return true }
                    return order == .newest ? left > right : left < right
                }
            case .speaker:
                let comparison = a.sermon!.speaker.localizedStandardCompare(b.sermon!.speaker)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .title: break
            }
            let comparison = a.title.localizedStandardCompare(b.title)
            return comparison == .orderedSame ? a.id.uuidString < b.id.uuidString : comparison == .orderedAscending
        }
        return report
    }
}
