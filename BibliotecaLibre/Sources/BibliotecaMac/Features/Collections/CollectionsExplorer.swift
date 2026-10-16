import LibronixCore
import SwiftUI

/// Presents real imported definitions. It does not turn a resource reference
/// into an available/readable book before the catalog can resolve that ID.
struct CollectionsExplorer: View {
    let snapshot: MetadataSnapshot?

    var body: some View {
        if let snapshot, snapshot.parsedDocumentCount > 0 {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header(snapshot)
                    collections(snapshot)
                    palettes(snapshot)
                    copyStyles(snapshot)
                    if !snapshot.warnings.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Algunas definiciones necesitan revisión", systemImage: "exclamationmark.circle")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(snapshot.warnings.joined(separator: "\n"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 36).padding(.vertical, 30)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(LibraryPalette.paper)
        } else {
            ContentUnavailableView("Tus colecciones de estudio", systemImage: "square.stack.3d.up",
                description: Text("Abre la carpeta general de tu biblioteca para incorporar sus colecciones, marcadores y estilos de copia."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LibraryPalette.paper)
        }
    }

    private func header(_ snapshot: MetadataSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("ORGANIZACIÓN Y ESTUDIO", systemImage: "square.stack.3d.up")
                .font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(LibraryPalette.accent)
            Text("Colecciones y herramientas")
                .font(.system(size: 32, weight: .medium, design: .serif))
            Text("Las agrupaciones y los estilos guardados con tu biblioteca, reunidos en un solo lugar.")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
            HStack(spacing: 20) {
                summary("Colecciones", snapshot.collections.count)
                summary("Paletas", snapshot.palettes.count)
                summary("Estilos de copia", snapshot.copyStyles.count)
            }.padding(.top, 7)
        }
    }

    private func summary(_ title: String, _ count: Int) -> some View {
        HStack(spacing: 7) {
            Text(count, format: .number).font(.system(size: 18, weight: .medium, design: .serif))
                .foregroundStyle(LibraryPalette.accent)
            Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    private func collections(_ snapshot: MetadataSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Colecciones de recursos", subtitle: "Agrupaciones originales para organizar el estudio de una obra, serie o tema.")
            ForEach(snapshot.collections) { collection in
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 13) {
                            Image(systemName: "books.vertical").font(.system(size: 20, weight: .light))
                                .foregroundStyle(LibraryPalette.accent).frame(width: 27)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(collection.title).font(.system(size: 15, weight: .medium, design: .serif))
                                Text("\(collection.resourceIDs.count) referencias de recursos")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        DisclosureGroup("Ver las referencias de la colección") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Las referencias identifican las obras de la agrupación. La correspondencia con los títulos del catálogo sigue en desarrollo.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                                Text(collection.resourceIDs.joined(separator: "\n"))
                                    .font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.top, 8)
                        }.font(.system(size: 11)).tint(LibraryPalette.accent)
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func palettes(_ snapshot: MetadataSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Marcadores de estudio", subtitle: "Paletas recuperadas para resaltar, clasificar y relacionar pasajes.")
            ForEach(snapshot.palettes) { palette in
                GroupBox {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(palette.styles.enumerated()), id: \.offset) { _, style in
                                HStack(spacing: 9) {
                                    Circle().fill(styleColor(style)).frame(width: 8, height: 8)
                                    Text(style.title).font(.system(size: 11.5))
                                    Spacer()
                                }
                            }
                            Text("Los estilos están disponibles para su consulta. Aplicarlos al texto se incorporará con el lector y las anotaciones.")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineSpacing(3).padding(.top, 5)
                        }.padding(.top, 12)
                    } label: {
                        HStack {
                            Text(palette.title).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("\(palette.styles.count) estilos").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .tint(LibraryPalette.accent).padding(5)
                }
            }
        }
    }

    private func copyStyles(_ snapshot: MetadataSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Estilos para copiar versículos", subtitle: "Las preferencias originales de formato y transliteración de tu biblioteca.")
            ForEach(snapshot.copyStyles) { style in
                GroupBox {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 9) {
                            preference("Formato de caracteres", option: "CharacterFormatting", style: style)
                            preference("Letras rojas", option: "RedLetter", style: style)
                            preference("Cita bibliográfica", option: "BibliographicCitation", style: style)
                            preference("Formato de párrafos", option: "ParagraphFormatting", style: style)
                            preference("Sólo texto bíblico", option: "BibleTextOnly", style: style)
                            if style.options["CopyFootnotes"] != nil {
                                preference("Copiar notas", option: "CopyFootnotes", style: style)
                            }
                            if style.languages["el"] == "Greek-LatinSBL" || style.languages["he"] == "Hebrew-LatinLogos" {
                                Label("Incluye transliteración de griego y hebreo", systemImage: "character.book.closed")
                                    .font(.system(size: 11)).foregroundStyle(LibraryPalette.accent)
                            }
                            Text("La copia del texto se habilitará cuando el lector pueda abrir el recurso.")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 3)
                        }.padding(.top, 12)
                    } label: {
                        Text(style.title).font(.system(size: 13, weight: .medium))
                    }
                    .tint(LibraryPalette.accent).padding(5)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .medium, design: .serif))
            Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineSpacing(3)
        }
    }

    private func preference(_ title: String, option: String, style: BibleCopyStyle) -> some View {
        HStack {
            Text(title).font(.system(size: 11.5))
            Spacer()
            Text(style.options[option] == "true" ? "Sí" : style.options[option] == "false" ? "No" : "Sin definir")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// A simple swatch communicates a declared color, not the full line/font/BMP
    /// renderer which will belong to AnnotationCore.
    private func styleColor(_ style: VisualMarkupStyle) -> Color {
        guard let hex = style.markup?.children.compactMap({ $0.attributes["color"] }).first,
              hex.hasPrefix("#"), hex.count == 7,
              let value = UInt32(hex.dropFirst(), radix: 16) else { return LibraryPalette.accent }
        return Color(red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
