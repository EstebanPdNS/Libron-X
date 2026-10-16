import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

struct ReaderLinkCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_LINK_CORPUS"] != nil))
    func originalRunDestinations() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_LINK_CORPUS"]))
        var records: [[String: Any]] = []; var bibleLinks = 0; var multiArticleLinks = 0
        for file in ["RVR60.LSF", "rvr60.lbxlls", "RVR95.LSF", "LBLA95.lbxlls", "NVI.lbxlls"] {
            let url = root.appendingPathComponent(file), modern = file.hasSuffix("lbxlls")
            let resource = LibraryResource(location: url, title: file, byteCount: Int64(try LegacyGraphicsService.fileStamp(url).size),
                format: modern ? .libronixLLS : .legacyLSF, support: .metadataOnly,
                provenance: modern ? .libronixMetadata : .legacyPublicMetadata)
            let page = try await ReaderSession.read(resource, .init(ordinal: 0, reference: "Ge 4:1"))
            let content = try #require(page.content)
            let inner = modern ? try await LibronixBookService.shared.prepare(resource) : resource
            let index = try LegacyIndicesReader.inspect(lsfURL: inner.location,
                lixURL: inner.indexLocation ?? inner.location.deletingPathExtension().appendingPathExtension("LIX"),
                allowUnavailableIndexBlocks: modern)
            let named = Dictionary(grouping: index.namedPositions, by: \.label)
            let attributed = content.runs.filter { $0.attribute != nil || $0.extendedAttributes != nil }
            #expect(page.inlineLinks.count == attributed.count && !page.inlineLinks.isEmpty)
            var noteRecords: [[String: Any]] = []
            for link in page.inlineLinks {
                let ordinal = try #require(link.sectionOrdinal)
                #expect((page.text as NSString).substring(with: link.range) == link.label)
                #expect(named[link.sourceName]?.contains { Int($0.articleID) == link.sectionOrdinal } == true)
                let note = try LegacyContentReader.readSection(lsfURL: inner.location, ordinal: ordinal)
                #expect(!note.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                let noteLinks = LegacyInlineLinks.resolve(content: note, namedPositions: index.namedPositions)
                for crossReference in noteLinks.links {
                    guard case .bible = crossReference.target else { continue }
                    bibleLinks += 1
                    let destination = try ReaderLinkPreviewState.destination(for: crossReference, resource: resource)
                    print("CHECK LINK \(file) \(crossReference.sourceName)")
                    let resolved = try await ReaderSession.read(resource, destination)
                    if resolved.passageParts.count > 1 {
                        multiArticleLinks += 1
                        for position in resolved.passageParts.indices {
                            let partDestination = try #require(resolved.passageDestination(at: position))
                            let part = try await ReaderSession.read(resource, partDestination)
                            #expect(part.destination.ordinal == resolved.passageParts[position].ordinal)
                            #expect(part.selection == resolved.passageParts[position].selection)
                            #expect(part.content == resolved.passageParts[position].content)
                        }
                    }
                    #expect(resolved.selection?.length ?? 0 > 0)
                    #expect(resolved.destination.reference.flatMap { LegacyPassageQuery.parse($0)?.normalizedKey }
                        == destination.reference.flatMap { LegacyPassageQuery.parse($0)?.normalizedKey })
                    if destination.endReference != nil { #expect(resolved.destination.endReference != nil) }
                }
                noteRecords.append([
                    "name": link.sourceName, "ordinal": ordinal,
                    "anchors": note.anchors.map { ["reference": $0.reference ?? "", "type": $0.dataTypeCode,
                        "flags": $0.flags, "offset": $0.characterOffset, "token": $0.sourceToken,
                        "scheme": $0.structuredReference.map { Array($0.schemeBytes) } ?? [],
                        "components": $0.structuredReference?.componentBits ?? []] as [String: Any] },
                    "runs": note.runs.map { ["text": $0.text, "flags": $0.sourceRunFlags, "offset": $0.characterOffset,
                        "attribute": $0.attribute ?? "", "strings": $0.extendedAttributes?.strings.map { LegacyResourceReader.decodeCP1252($0) } ?? [],
                        "values": $0.extendedAttributes?.values ?? []] as [String: Any] }
                ])
            }
            let first = try #require(page.inlineLinks.first)
            let preview = try await ReaderSession.read(resource, .init(ordinal: try #require(first.sectionOrdinal)))
            #expect(preview.destination.ordinal == first.sectionOrdinal && !preview.text.isEmpty)
            let runs: [[String: Any]] = content.runs.filter { $0.attribute != nil || $0.extendedAttributes != nil }.map { run in
                let candidates = [run.attribute].compactMap { $0 } + (run.extendedAttributes?.strings.map { LegacyResourceReader.decodeCP1252($0) } ?? [])
                let targets = candidates.flatMap { named[$0] ?? [] }
                return ["offset":run.characterOffset,"length":run.logicalCharacterCount,"flags":run.sourceRunFlags,
                 "style":run.styleIdentifier,"label":run.text,"attribute":run.attribute ?? "",
                 "strings":run.extendedAttributes?.strings.map { String(decoding:$0,as:UTF8.self) } ?? [],
                 "values":run.extendedAttributes?.values ?? [],"extensionFlags":run.extendedAttributes?.flags ?? 0,
                 "namedTargets":targets.map { ["name":$0.label,"ordinal":$0.articleID] as [String:Any] }]
            }
            let noteLinks: [[String:Any]] = (preview.content?.runs ?? []).filter { $0.attribute != nil || $0.extendedAttributes != nil }.map {
                ["label":$0.text,"attribute":$0.attribute ?? "", "strings":$0.extendedAttributes?.strings.map { LegacyResourceReader.decodeCP1252($0) } ?? []]
            }
            records.append(["file":file,"ordinal":page.destination.ordinal,"characters":page.text.utf16.count,"runs":runs,
                            "firstNoteLinks":noteLinks,"firstNoteCharacters":preview.text.utf16.count,"noteArticles":noteRecords])
            print("Original run destinations: \(file): \(runs.count) attributed runs in physical article \(page.destination.ordinal)")
        }
        #expect(bibleLinks == 62 && multiArticleLinks == 1)
        print("Original Bible links: \(bibleLinks) resolved; \(multiArticleLinks) multi-article passage verified part by part")
        if let output = ProcessInfo.processInfo.environment["LIBRONX_LINK_RECEIPT"] {
            try JSONSerialization.data(withJSONObject: records, options:[.prettyPrinted,.sortedKeys])
                .write(to:URL(fileURLWithPath:output),options:.atomic)
        }
    }
}
