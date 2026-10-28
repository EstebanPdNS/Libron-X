import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct ReadingPlanPersistenceTests {
    @Test func saveCompletionReopenAndRejectConcurrentWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json")
        let first = WorkspacePersonalState(url: url), stale = WorkspacePersonalState(url: url)
        let day = try ReadingDay(year: 2024, month: 2, day: 29)
        let plan = try ReadingPlan.schedule(title: "Own", references: ["John 1", "John 2"], start: day, weekdays: Set(1...7))
        try first.editReadingPlans { $0.plans.append(plan) }
        #expect(throws: PersonalStateError.self) { try stale.editReadingPlans { $0.plans.append(plan) } }
        #expect(stale.readingPlans.plans.isEmpty)
        try first.editReadingPlans { $0.plans[0].readings[0].completed = true }
        let reopened = WorkspacePersonalState(url: url)
        #expect(reopened.readingPlans.plans[0].readings[0].completed)
        #expect(reopened.readingPlans.plans[0].visibleReadings(hideCompleted: true).map(\.reference) == ["John 2"])
    }
    @Test func futureSchemaDoesNotOverwriteOriginalFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("reading-plans.json"), bytes = Data(#"{"schemaVersion":99,"plans":[]}"#.utf8)
        try bytes.write(to: path)
        let state = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        #expect(state.readingPlansLoadError != nil)
        #expect(throws: PersonalStateError.self) { try state.editReadingPlans { $0.plans = [] } }
        #expect(try Data(contentsOf: path) == bytes)
    }
}
