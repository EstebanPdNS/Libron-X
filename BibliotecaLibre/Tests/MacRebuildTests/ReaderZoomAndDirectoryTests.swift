import AppKit
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct ReaderZoomAndDirectoryTests {
    private func workspace(_ fixture: AuthoredReaderFixture) -> StudyWorkspace {
        StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")),
                       resourceVisibility: LibraryResourceVisibility(url: fixture.root.appendingPathComponent("hidden.json")))
    }
    @Test func sliderUsesFivePercentStepsWithoutChangingLegacyWorkspaceValues() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Source"]]); defer { fixture.remove() }
        let reader = ReaderSession(resource: fixture.resources[0])
        reader.textScale = 1.49
        #expect(reader.textScale == 1.49)
        for percent in stride(from: 0, through: 300, by: 5) {
            let scale = try #require(ReaderZoom.sliderScale(for: Double(percent)))
            reader.textScale = scale
            #expect(abs(reader.textScale * 100 - Double(percent)) < 0.0001)
        }
        #expect(ReaderZoom.sliderScale(for: 82) == 0.8)
        #expect(ReaderZoom.sliderScale(for: 83) == 0.85)
        #expect(ReaderZoom.sliderScale(for: -1) == 0)
        #expect(ReaderZoom.sliderScale(for: 301) == 3)
        #expect(ReaderZoom.sliderScale(for: .nan) == nil)
        #expect(ReaderZoom.sliderScale(for: .infinity) == nil)
        let w = workspace(fixture); defer { w.shutdown() }
        let savedReader = w.open(fixture.resources[0], startReading: false)
        savedReader.textScale = try #require(ReaderZoom.sliderScale(for: 83))
        let archive = try JSONDecoder().decode(WorkspaceArchive.self, from: JSONEncoder().encode(w.archive()))
        #expect(archive.panes.first?.scale == 0.85)
    }
    @Test func zoomAcceptsWholeSliderRangeAndRejectsInvalidValuesWithoutLosingPreviousSize() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Original 😀 text"]]); defer { fixture.remove() }
        let reader = ReaderSession(resource: fixture.resources[0])
        for scale in [0, 0.01, 0.49, 1, 1.49, 3] {
            reader.textScale = scale
            #expect(reader.textScale == scale)
            #expect(reader.renderingScale > 0 && reader.renderingScale.isFinite)
            #expect(reader.renderingScale == (scale == 0 ? 1.5 : scale * 1.5))
        }
        reader.textScale = 1.49
        for invalid in [-0.01, 3.01, .infinity, -.infinity, .nan] {
            reader.textScale = invalid
            #expect(reader.textScale == 1.49)
        }
        #expect(reader.resource == fixture.resources[0] && reader.history.isEmpty)
    }
    @Test func zeroAndSubFiftyPercentSurviveDiskSerializationAndWorkspaceRestore() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Unmodified source"]]); defer { fixture.remove() }
        let source = workspace(fixture); source.resources = fixture.resources
        for scale in [0, 0.01, 0.49, 3] {
            source.open(fixture.resources[0], startReading: false).textScale = scale
        }
        let url = fixture.root.appendingPathComponent("zoom-workspace.json")
        try JSONEncoder().encode(source.archive()).write(to: url)
        let saved = try JSONDecoder().decode(WorkspaceArchive.self, from: Data(contentsOf: url))
        try saved.validate()
        let recovered = workspace(fixture); try recovered.restore(saved)
        #expect(recovered.readers.map(\.textScale) == [0, 0.01, 0.49, 3])
        var invalid = saved; invalid.panes[0].scale = -0.01
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid.panes[0].scale = 3.01
        #expect(throws: (any Error).self) { try invalid.validate() }
        source.shutdown(); recovered.shutdown()
    }
    @Test func smallZoomActuallyScalesTextAndKeepsUnicodeContentIntact() throws {
        let text = "Árbol α 😀 متن"
        for scale in [0.01, 0.25, 1, 3] {
            let result = ReaderTypography.render(text: text, content: nil, typography: nil, scale: ReaderZoom.renderingScale(scale))
            let font = try #require(result.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(abs(font.pointSize - 18 * scale) < 0.001)
            #expect(result.text.string == text && result.text.length == text.utf16.count)
        }
    }
    @Test func directoryFollowsSelectionThenLibraryRootAndOpensTheActualFolder() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Source"]]); defer { fixture.remove() }
        let w = workspace(fixture); w.libraryRoot = fixture.root
        let nested = fixture.root.appendingPathComponent("Nested resources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let url = nested.appendingPathComponent("book.LSF")
        try Data(contentsOf: fixture.resources[0].location).write(to: url)
        let resource = LibraryResource(location: url, title: "Nested book", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        w.resources = [resource]
        #expect(w.currentResourceDirectory == fixture.root.standardizedFileURL)
        w.librarySelection = resource.id
        #expect(w.currentResourceDirectory == nested.standardizedFileURL)
        var opened: URL?
        w.openCurrentResourceDirectory { opened = $0; return true }
        #expect(opened == nested.standardizedFileURL && w.error == nil)
        w.libraryQuery = "No matching resource"
        #expect(w.currentResourceDirectory == fixture.root.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    @Test func unavailableDirectoryCannotBeOpenedAndFinderFailureIsReported() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Source"]]); defer { fixture.remove() }
        let w = workspace(fixture)
        var opened = false
        for invalid in [nil, URL(string: "https://example.com/resources"), fixture.resources[0].location,
                        fixture.root.appendingPathComponent("missing")] as [URL?] {
            w.libraryRoot = invalid
            #expect(w.currentResourceDirectory == nil)
            w.openCurrentResourceDirectory { _ in opened = true; return true }
        }
        #expect(!opened)
        w.libraryRoot = fixture.root
        w.openCurrentResourceDirectory { _ in false }
        #expect(w.error == L("No se pudo abrir el directorio en Finder."))
    }
}

@MainActor struct SettingsResourceDirectoryTests {
    @Test func settingsSelectionResolvesHiddenResourceWithoutUsingAnotherWindowsSelection() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Source"]]); defer { fixture.remove() }
        let w = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")),
            resourceVisibility: LibraryResourceVisibility(url: fixture.root.appendingPathComponent("hidden.json")))
        w.libraryRoot = fixture.root
        let nested = fixture.root.appendingPathComponent("Hidden resources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let resource = LibraryResource(location: nested.appendingPathComponent("book.LSF"), title: "Hidden", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        w.resources = [resource]
        try w.hideLibraryResources([resource.id]); w.resources = []
        #expect(w.currentResourceDirectory == fixture.root.standardizedFileURL)
        #expect(w.resourceDirectory(for: resource.id) == nested.standardizedFileURL)
        var opened: URL?
        w.openResourceDirectory(for: resource.id) { opened = $0; return true }
        #expect(opened == nested.standardizedFileURL)
        #expect(w.resourceDirectory(for: "/unimported/another.LSF") == fixture.root.standardizedFileURL)
    }
}
