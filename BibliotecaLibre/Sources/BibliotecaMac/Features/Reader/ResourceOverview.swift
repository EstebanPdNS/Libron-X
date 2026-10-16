import LibronixCore
import SwiftUI

/// A resource overview displays real recovered metadata. It never substitutes
/// generated text for book content while a decoder is still unavailable.
struct ResourceOverview: View {
    let resource: LibraryResource
    let reveal: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    Label("DETALLE DEL RECURSO", systemImage: "book.closed")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: reveal) { Image(systemName: "folder") }.buttonStyle(.plain)
                        .help("Mostrar el archivo original en Finder").accessibilityLabel("Mostrar en Finder")
                }
                HStack(alignment: .center, spacing: 30) {
                    BookCover(resource: resource).frame(width: 152, height: 214)
                    VStack(alignment: .leading, spacing: 13) {
                        Text(resource.format.displayName.uppercased())
                            .font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(LibraryPalette.accent)
                        Text(resource.title).font(.system(size: 28, weight: .medium, design: .serif)).lineSpacing(3)
                        if let author = resource.author {
                            Text(author).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Text(resource.isHelp ? "Ayuda de la biblioteca" : "Recurso de tu colección")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider().padding(.top, 5)
                VStack(alignment: .leading, spacing: 18) {
                    Text("Acerca de este archivo").font(.system(size: 21, weight: .medium, design: .serif))
                    metadataRow("Formato", value: resource.format.displayName)
                    metadataRow("Archivo", value: resource.fileName)
                    metadataRow("Tamaño", value: ByteCountFormatter.string(fromByteCount: resource.byteCount, countStyle: .file))
                    if !resource.languages.isEmpty {
                        metadataRow("Idioma declarado", value: resource.languages.joined(separator: ", "))
                    }
                    metadataRow("Metadatos", value: resource.provenance == .legacyPublicMetadata
                        ? "Recuperados del archivo original" : "Nombre del archivo; título pendiente de recuperación")
                    if let index = resource.indexLocation {
                        metadataRow("Índice asociado", value: index.lastPathComponent)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label(statusTitle, systemImage: resource.support == .invalidFile ? "exclamationmark.circle" : "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text(statusDescription).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                    if !resource.warnings.isEmpty {
                        Text(resource.warnings.joined(separator: "\n"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(LibraryPalette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                    Text("El archivo original se conserva sin modificaciones.")
                }.font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 42).padding(.vertical, 30)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(LibraryPalette.paper)
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            Text(value).font(.system(size: 11.5)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var statusTitle: String {
        resource.support == .invalidFile ? "Este archivo necesita revisión" : resource.format == .legacyLSF ? "Texto legado con compatibilidad parcial" : "Catalogado; lectura del contenido pendiente"
    }
    private var statusDescription: String {
        switch resource.support {
        case .metadataOnly:
            "Se han recuperado los metadatos del recurso. La pestaña Lectura abre los artículos compatibles y permite ir a pasajes comprobados. La presentación completa y los índices de búsqueda continúan en desarrollo."
        case .opaqueContainer:
            "El recurso ha sido identificado. La compatibilidad necesaria para leer su contenido todavía está en desarrollo."
        case .invalidFile:
            "La estructura del archivo no pudo validarse. Se conserva intacto y no se ha intentado corregirlo automáticamente."
        }
    }
}
