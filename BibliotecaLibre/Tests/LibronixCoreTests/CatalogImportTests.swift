import Foundation
import Testing
@testable import LibronixCore

struct CatalogImportTests {
    @Test("Catalog search ignores case and Latin accents without searching book content")
    func catalogSearch() {
        let resource = LibraryResource(location: URL(fileURLWithPath: "/fixture/recurso.lbxlls"),
            title: "Teología y oración", author: "Autor sintético", byteCount: 16,
            format: .libronixLLS, support: .opaqueContainer, provenance: .fileName)
        #expect(CatalogQuery(text: "TEOLOGIA").apply(to: [resource]).count == 1)
        #expect(CatalogQuery(text: "sintetico").apply(to: [resource]).count == 1)
        #expect(CatalogQuery(text: "texto no presente").apply(to: [resource]).isEmpty)
        #expect(CatalogQuery(metadataOnly: true).apply(to: [resource]).isEmpty)
    }

    @Test("Imports a recognized container as opaque and preserves its original bytes")
    func readOnlyImport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("SAMPLE.LBXLLS")
        let original = Data([0x4c,0x54,0x45,0x53,0,0,1,1,8,0,0,0,0,0,0,0])
        try original.write(to: file)
        let snapshot = try await LibraryImporter().importDirectory(at: directory)
        #expect(snapshot.resources.count == 1)
        #expect(snapshot.resources.first?.support == .opaqueContainer)
        #expect(snapshot.resources.first?.provenance == .fileName)
        #expect(snapshot.resources.first?.title == "SAMPLE")
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("Invalid headers remain visible with a controlled unsupported status")
    func invalidHeader() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("broken.lbxoeb")
        try Data("not a resource".utf8).write(to: file)
        let result = try await LibraryImporter().importDirectory(at: directory)
        #expect(result.resources.count == 1)
        #expect(result.resources.first?.support == .invalidFile)
        #expect(try String(contentsOf: file, encoding: .utf8) == "not a resource")
    }

    @Test("A symlink cannot silently import a file outside the selected library")
    func skipsSymbolicLinks() async throws {
        let directory = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let target = outside.appendingPathComponent("private.lbxlls")
        try Data([0x4c,0x54,0x45,0x53,0,0,1,1]).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.lbxlls"),
            withDestinationURL: target)
        let result = try await LibraryImporter().importDirectory(at: directory)
        #expect(result.resources.isEmpty)
    }

    @Test("Missing directories are an error, never an empty successful import")
    func missingDirectory() async {
        await #expect(throws: LibraryImportError.self) {
            try await LibraryImporter().importDirectory(at: URL(fileURLWithPath: "/missing-\(UUID().uuidString)"))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("biblioteca-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
