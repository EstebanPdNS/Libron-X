import AppKit
import Foundation
import Testing
import CSQLite
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct DevotionalNavigationTests {
    private func settle(_ reader: ReaderSession) async throws {
        for _ in 0..<500 where reader.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!reader.isLoading)
    }
    @Test(arguments: [false, true]) func exactDatesAndMissingDaysPreserveSourceAndHistory(normalized: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("owned.devi"); var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw LibronError.invalid("Fixture could not open") }
        let sql = "CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Owned daily','OD','Fixture'); CREATE TABLE Devotional(Month INTEGER,Day INTEGER,Devotion TEXT); INSERT INTO Devotional VALUES(1,1,'January first'),(1,3,'January third'),(2,29,'Leap day');"
        let result = sqlite3_exec(db, sql, nil, nil, nil); sqlite3_close(db); #expect(result == SQLITE_OK)
        let original = try Data(contentsOf: url)
        let inspected = try ESwordResource.inspect(url)
        let resource: LibraryResource
        if normalized {
            let package = try LibronPackage.create(inspected, in: root.appendingPathComponent("library"), backup: false)
            resource = try LibronPackage.read(package).1
            _ = try await LibronNativeNormalizer().convert(resource)
        } else { resource = inspected }
        let reader = ReaderSession(resource: resource); #expect(reader.isDevotional)
        reader.load(.init(ordinal: 0)); try await settle(reader)
        #expect(reader.page?.text.contains("January first") == true)
        let history = reader.history
        reader.openDevotional(try ReadingDay(year: 2025, month: 1, day: 2)); try await settle(reader)
        #expect(reader.page?.text.contains("January first") == true && reader.history == history && reader.error != nil)
        reader.openDevotional(try ReadingDay(year: 2025, month: 1, day: 3)); try await settle(reader)
        #expect(reader.page?.text.contains("January third") == true && reader.error == nil)
        reader.openDevotional(try ReadingDay(year: 2024, month: 2, day: 29)); try await settle(reader)
        #expect(reader.page?.text.contains("Leap day") == true && reader.canGoBack)
        reader.goBack(); try await settle(reader)
        #expect(reader.page?.text.contains("January third") == true)
        #expect(try Data(contentsOf: url) == original)
    }
    @Test func changedSourceCannotCommitAnOldDateDestination() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("changed.devi"); var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw LibronError.invalid("Fixture could not open") }
        let sql = "CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Owned daily','OD','Fixture'); CREATE TABLE Devotional(Month INTEGER,Day INTEGER,Devotion TEXT); INSERT INTO Devotional VALUES(1,1,'Original'),(1,2,'Next');"
        let result = sqlite3_exec(db, sql, nil, nil, nil); sqlite3_close(db); #expect(result == SQLITE_OK)
        let resource = try ESwordResource.inspect(url)
        let reader = ReaderSession(resource: resource, loader: { resource, destination in
            let result = try await ESwordReader.read(resource, destination)
            if destination.ordinal == 1 {
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: resource.location.path)
            }
            return result
        })
        reader.load(.init(ordinal: 0)); try await settle(reader)
        let history = reader.history
        reader.openDevotional(try ReadingDay(year: 2025, month: 1, day: 2)); try await settle(reader)
        #expect(reader.page?.text.contains("Original") == true && reader.history == history && reader.error != nil)
    }
}
