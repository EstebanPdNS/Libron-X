import AppKit
import UniformTypeIdentifiers
import LibronixCore

enum BibliographyExportKind:String,CaseIterable {
    case text="txt",html,json
    var title:String { switch self { case .text:"Texto";case .html:"HTML";case .json:"JSON" } }
    var type:UTType { switch self { case .text:.plainText;case .html:.html;case .json:.json } }
}
@MainActor enum BibliographyExportActions {
    static func data(_ report:BibliographyReport,kind:BibliographyExportKind,labels:BibliographyReportLabels) throws -> Data {
        switch kind {
        case .text:
            if ResourceCitationActions.style != .catalog {
                return Data((labels.title + "\n" + report.entries.map { ResourceCitation.text($0,style:ResourceCitationActions.style,unknown:labels.unknown) }.joined(separator:"\n\n")).utf8)
            }
            return Data(BibliographyReportRenderer.plainText(report,labels:labels).utf8)
        case .html:
            if ResourceCitationActions.style != .catalog {
                return Data(("<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\"></head><body>" + report.entries.map { "<p>" + ResourceCitation.html($0,style:ResourceCitationActions.style,unknown:labels.unknown) + "</p>" }.joined() + "</body></html>").utf8)
            }
            return Data(BibliographyReportRenderer.html(report,labels:labels).utf8)
        case .json:return try BibliographyReportRenderer.json(report)
        }
    }
    static func copy(_ controller:BibliographyController,pasteboard:NSPasteboard = .general,workspace:StudyWorkspace? = nil) {
        if let workspace { refresh(controller,workspace:workspace) }
        guard controller.canExport,let report=controller.report else { return }
        guard let bytes=try? data(report,kind:.text,labels:BibliographyLocalization.labels),let text=String(data:bytes,encoding:.utf8) else { return }
        pasteboard.clearContents();pasteboard.setString(text,forType:.string)
    }
    static func export(_ controller:BibliographyController,kind:BibliographyExportKind,workspace:StudyWorkspace) {
        refresh(controller,workspace:workspace)
        guard controller.canExport,let report=controller.report else { return }
        do {
            let citationStyle=ResourceCitationActions.style
            let bytes=try data(report,kind:kind,labels:BibliographyLocalization.labels)
            let panel=NSSavePanel();panel.title=L("Exportar bibliografía");panel.allowedContentTypes=[kind.type]
            panel.nameFieldStringValue="Bibliografia." + kind.rawValue
            panel.begin { response in
                guard response == .OK,let url=panel.url else { return }
                refresh(controller,workspace:workspace)
                guard controller.canExport,controller.report?.id == report.id,controller.report?.order == report.order,ResourceCitationActions.style == citationStyle else {
                    workspace.error=L("El informe cambió. Vuelve a exportarlo.");return
                }
                do { try validateDestination(url,resources:workspace.resources,libraryRoot:workspace.libraryRoot);try bytes.write(to:url,options:.atomic) }
                catch { workspace.error=error.localizedDescription }
            }
        } catch { workspace.error=error.localizedDescription }
    }
    private static func refresh(_ controller:BibliographyController,workspace:StudyWorkspace) {
        controller.updateContext(.init(resources:workspace.resources,collections:workspace.collections.sets,collectionsError:workspace.collections.loadError))
    }
    static func validateDestination(_ url:URL,resources:[LibraryResource],libraryRoot:URL?) throws {
        guard url.isFileURL else { throw RebuildError.unsupportedFormat }
        // Resolve the existing ancestor first: Foundation may leave symlinks
        // unresolved when the final export filename does not exist yet.
        func canonical(_ url:URL) -> URL {
            var ancestor=url.standardizedFileURL,tail:[String]=[]
            while !FileManager.default.fileExists(atPath:ancestor.path),ancestor.path != "/" {
                tail.insert(ancestor.lastPathComponent,at:0);ancestor=ancestor.deletingLastPathComponent()
            }
            var value=ancestor.resolvingSymlinksInPath()
            for component in tail { value.appendPathComponent(component) }
            return value.standardizedFileURL
        }
        let target=canonical(url)
        func same(_ other:URL) -> Bool { target == canonical(other) }
        let catalogs=resources.compactMap(\.packageLocation).map { $0.deletingLastPathComponent().appendingPathComponent("catalog.json") }
            + (libraryRoot.map { [$0.appendingPathComponent("catalog.json")] } ?? [])
        guard !catalogs.contains(where:same),!resources.contains(where:{ resource in
            if same(resource.location) || resource.indexLocation.map(same) == true { return true }
            if resource.id.hasPrefix("/"),same(URL(fileURLWithPath:resource.id)) { return true }
            guard let package=resource.packageLocation.map(canonical)?.path else { return false }
            return target.path == package || target.path.hasPrefix(package + "/")
        }) else { throw PersonalStateError.invalid(L("El informe no puede sustituir un recurso ni el catálogo de la biblioteca.")) }
    }
}
