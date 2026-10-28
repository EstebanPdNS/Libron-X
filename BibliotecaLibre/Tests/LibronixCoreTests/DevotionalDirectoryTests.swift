import Foundation
import Testing
@testable import LibronixCore
#if canImport(CSQLite)
import CSQLite
#endif

struct DevotionalDirectoryTests {
    @Test func sparseDaysAreExactAndLeapDaysAreNotInvented() throws {
        let index = try DevotionalDirectory(entries: [(4, "12/31"), (0, "1/1"), (2, "2/29")])
        #expect(try index.ordinal(for: ReadingDay(year: 2025, month: 1, day: 1)) == 0)
        #expect(try index.ordinal(for: ReadingDay(year: 2024, month: 2, day: 29)) == 2)
        #expect(try index.ordinal(for: ReadingDay(year: 2025, month: 2, day: 28)) == nil)
        #expect(throws: (any Error).self) { try ReadingDay(year: 2025, month: 2, day: 29) }
        #expect(throws: DevotionalDirectoryError.duplicateDate) { try DevotionalDirectory(entries: [(0, "1/1"), (1, "01/01")]) }
        #expect(throws: DevotionalDirectoryError.invalidDirectory) { try DevotionalDirectory(entries: [(0, "2/30")]) }
        #expect(throws: DevotionalDirectoryError.invalidDirectory) { try DevotionalDirectory(entries: [(0, "1/1"), (0, "1/2")]) }
    }

    #if canImport(CSQLite)
    @Test func authoredDevotionalResolvesDatesToTheOriginalSQLiteEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("owned.devi")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw LibronError.invalid("Fixture could not open") }
        let sql = "CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Owned daily','OD','Authored fixture'); CREATE TABLE Devotional(Month INTEGER,Day INTEGER,Devotion TEXT); INSERT INTO Devotional VALUES(12,31,'End'),(2,29,'Leap'),(1,1,'New year');"
        let result = sqlite3_exec(db, sql, nil, nil, nil); sqlite3_close(db)
        #expect(result == SQLITE_OK)
        let original = try Data(contentsOf: url)
        #expect(try ESwordResource.inspect(url).libron?.resourceType == "Devocional")
        let first = try ESwordResource.page(url, ordinal: 0)
        let directory = try DevotionalDirectory(entries: first.contents.enumerated().map { ($0.offset, $0.element) })
        for (year, month, day, expected) in [(2025, 1, 1, "New year"), (2024, 2, 29, "Leap"), (2025, 12, 31, "End")] {
            let date = try ReadingDay(year: year, month: month, day: day)
            let resolved = try directory.ordinal(for: date)
            let ordinal = try #require(resolved)
            #expect(try ESwordResource.page(url, ordinal: ordinal).entries.first?.body == expected)
        }
        #expect(try Data(contentsOf: url) == original)
    }
    #endif
}
