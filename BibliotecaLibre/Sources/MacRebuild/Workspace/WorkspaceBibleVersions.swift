import Foundation
import LibronixCore

/// Uses source bibliographic declarations rather than filenames or translated titles.
actor BibleVersionCatalog {
    private var cache: [URL: (LegacyGraphicSourceStamp, Bool)] = [:]
    func versions(in resources: [LibraryResource], observed: Set<String>) throws -> [LibraryResource] {
        var result: [LibraryResource] = []
        for resource in resources {
            try Task.checkCancellation()
            if observed.contains(resource.id) {
                if let stamp = try? LegacyGraphicsService.fileStamp(resource.location) { cache[resource.location] = (stamp, true) }
                result.append(resource); continue
            }
            guard resource.format != .libronixOEB, !resource.isHelp,
                  let stamp = try? LegacyGraphicsService.fileStamp(resource.location) else { continue }
            let isBible: Bool
            if let cached = cache[resource.location], cached.0 == stamp { isBible = cached.1 }
            else {
                do {
                    if resource.format == .libronixLLS {
                        let metadata = try LibronixBookArchive.inspect(at: resource.location).metadata()
                        isBible = metadata.xml.child(named: "metadata")?.child(named: "dc-metadata")?.children.contains {
                            ($0.attributes["name"] == "dc.type:lbx-types") && $0.text.lowercased().hasPrefix("text.monograph.bible.") || ($0.attributes["name"] == "dc.type:lbx-types" && $0.text.lowercased() == "text.monograph.bible")
                        } == true
                    } else {
                        let metadata = try LegacyResourceReader.inspect(lsfURL: resource.location).lsf
                        let title = metadata.uniformTitle?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        isBible = title == "bible" || title.hasPrefix("bible.") || title == "biblia" || title.hasPrefix("biblia.")
                    }
                    cache[resource.location] = (stamp, isBible)
                } catch { continue }
            }
            if isBible { result.append(resource) }
        }
        return result.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

@MainActor extension StudyWorkspace {
    func refreshBibleVersionChoices() async {
        let resources = availableResources, observed = Set(bibleReaders.map { $0.resource.id })
        do {
            let versions = try await bibleVersionCatalog.versions(in: resources, observed: observed)
            guard !Task.isCancelled, resources == availableResources else { return }
            availableBibleVersions = versions
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    func cycleBibleVersion(_ reader: ReaderSession, backwards: Bool = false) {
        guard readers.contains(where: { $0 === reader }), !reader.isLoading,
              reader.canSynchronizeBible, let reference = reader.currentReference else { return }
        bibleVersionTask?.cancel()
        let resources = availableResources, observed = Set(bibleReaders.map { $0.resource.id })
        let originalID = reader.resource.id, groupID = reader.parallelSetID
        let group = groupID.flatMap { id in parallelBibleSets.sets.first { $0.id == id } }
        if groupID != nil, group == nil { reader.error = L("El grupo de Biblias ya no está disponible."); return }
        bibleVersionTask = Task { [weak self, weak reader, bibleVersionCatalog] in
            do {
                let versions: [LibraryResource]
                if let group { versions = group.members.compactMap { $0.resolve(in: resources) } }
                else { versions = try await bibleVersionCatalog.versions(in: resources, observed: observed) }
                guard let self, let reader, !Task.isCancelled, self.readers.contains(where: { $0 === reader }),
                      reader.resource.id == originalID, reader.parallelSetID == groupID,
                      groupID.flatMap({ id in self.parallelBibleSets.sets.first { $0.id == id } }) == group,
                      reader.currentReference == reference, !reader.isLoading,
                      versions.count > 1, let index = versions.firstIndex(where: { $0.id == originalID }) else { return }
                let candidates = (1..<versions.count).map { offset in
                    versions[(index + (backwards ? versions.count - offset : offset)) % versions.count]
                }
                let currentResources = Set(self.availableResources)
                reader.changeBibleVersion(candidates: candidates.filter { currentResources.contains($0) }, reference: reference) { [weak self, weak reader] in
                    guard let self, let reader else { return }; self.connect(reader)
                }
            } catch is CancellationError { }
            catch { self?.error = error.localizedDescription }
        }
    }
}
