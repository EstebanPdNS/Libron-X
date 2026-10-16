import Foundation
import Testing
@testable import LibronixCore
#if os(Windows)
import WinSDK
#endif

struct ResourceDirectoryEnumeratorTests {
    @Test func nestedUnicodeEntriesKeepURLsAndSkipDotDirectories() throws {
        try withDirectory { root in
            let nested = root.appendingPathComponent("Greek α 😀", isDirectory: true)
            let hidden = root.appendingPathComponent(".private", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
            try Data([1]).write(to: nested.appendingPathComponent("BOOK.LSF"))
            try Data([2]).write(to: root.appendingPathComponent("BOOK.LIX"))
            try Data([3]).write(to: root.appendingPathComponent(".hidden.LSF"))
            try Data([4]).write(to: hidden.appendingPathComponent("private.LSF"))
            let entries = try enumerate(root)
            #expect(Set(entries.map(\.lastPathComponent)) == ["Greek α 😀", "BOOK.LSF", "BOOK.LIX"])
            let book = try #require(entries.first { $0.lastPathComponent == "BOOK.LSF" })
            // Darwin may canonicalize /var to /private/var during enumeration.
            // Compare the actual destination, not Foundation's URL spelling.
            #expect(book.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path ==
                    nested.resolvingSymlinksInPath().standardizedFileURL.path)
            #expect(try Data(contentsOf: book) == Data([1]))
        }
    }

    @Test func explicitSkipDescendantsPreservesFollowingSiblings() throws {
        try withDirectory { root in
            let directory = root.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appendingPathComponent("inside.LSF"))
            try Data([2]).write(to: root.appendingPathComponent("outside.LSF"))
            let iterator = try #require(ResourceDirectoryEnumerator(root: root, keys: [.isDirectoryKey]))
            var names: [String] = []
            while let value = try iterator.nextURL() {
                names.append(value.lastPathComponent)
                if value.lastPathComponent == "nested" { iterator.skipDescendants() }
            }
            #expect(Set(names) == ["nested", "outside.LSF"])
        }
    }

    @Test func missingDirectoryReturnsNoIterator() throws {
        try withDirectory { root in
            #expect(ResourceDirectoryEnumerator(root: root.appendingPathComponent("missing"), keys: []) == nil)
        }
    }

    #if os(Windows)
    @Test func nativeHiddenAttributeExcludesAVisibleFilename() throws {
        try withDirectory { root in
            let file = root.appendingPathComponent("hidden-by-attribute.LSF")
            try Data([1]).write(to: file)
            let path = file.path.replacingOccurrences(of: "/", with: "\\")
            let changed = path.withCString(encodedAs: UTF16.self) { SetFileAttributesW($0, DWORD(FILE_ATTRIBUTE_HIDDEN)) }
            defer { _ = path.withCString(encodedAs: UTF16.self) { SetFileAttributesW($0, DWORD(FILE_ATTRIBUTE_NORMAL)) } }
            #expect(changed)
            #expect(try enumerate(root).isEmpty)
        }
    }
    #endif

    private func enumerate(_ root: URL) throws -> [URL] {
        let iterator = try #require(ResourceDirectoryEnumerator(root: root, keys: [.isDirectoryKey]))
        var result: [URL] = []
        while let value = try iterator.nextURL() { result.append(value) }
        return result
    }

    private func withDirectory(_ operation: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.standardizedFileURL
        let root = parent.appendingPathComponent("libronx-enumeration-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root)
    }
}
