import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct PrayerJournalPersistenceTests {
    @Test func journalIsIndependentPersistentAndRejectsConcurrentWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json"), first = WorkspacePersonalState(url: url), stale = WorkspacePersonalState(url: url)
        let category = PrayerCategory(name: "Owned category"), start = try ReadingDay(year: 2025, month: 1, day: 1)
        let request = PrayerRequest(title: "Owned prayer", details: "Local example", categoryID: category.id, start: start, repetition: .daily, isPrivate: true)
        try first.editPrayerJournal { $0.categories.append(category); $0.requests.append(request) }
        #expect(throws: PersonalStateError.self) { try stale.editPrayerJournal { $0.requests.append(request) } }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        var updated = request; try updated.markPrayed(on: start); try updated.setAnswered(on: start)
        try first.savePrayerRequest(original: request, replacement: updated)
        #expect(throws: PersonalStateError.self) { try first.savePrayerRequest(original: request, replacement: updated) }
        let restored = WorkspacePersonalState(url: url)
        #expect(restored.prayerJournal == first.prayerJournal && restored.prayerJournal.requests.first?.isPrivate == true)
        #expect(restored.prayerJournal.requests.first?.answered == start)
    }
    @Test func futureJournalIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("prayer-journal.json"), bytes = Data(#"{"schemaVersion":99,"categories":[],"requests":[]}"#.utf8)
        try bytes.write(to: path)
        let state = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        #expect(state.prayerJournalLoadError != nil)
        #expect(throws: PersonalStateError.self) { try state.editPrayerJournal { $0.requests = [] } }
        #expect(try Data(contentsOf: path) == bytes)
    }
}
