import AppKit
import SwiftUI

struct FeatureHelpView: View {
    let topic: FeatureHelpTopic
    let close: () -> Void
    @Bindable private var preferences = AppPreferences.shared
    var body: some View {
        VStack(spacing: 0) {
            ScrollView { FeatureHelpContent(topic: topic, language: preferences.language) }
            FeatureHelpFooter(close: close)
        }.frame(minWidth: 420)
    }
}

private struct FeatureHelpContent: View {
    let topic: FeatureHelpTopic
    let language: AppLanguage
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(AppStrings.text(topic.title, language: language), systemImage: "questionmark.circle")
                .font(.title2.weight(.semibold))
            FeatureHelpVisual(topic: topic, language: language)
            ForEach(topic.paragraphs, id: \.self) { key in
                Text(AppStrings.text(key, language: language))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FeatureHelpFooter: View {
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack { Spacer(); Button(L("Listo"), action: close).keyboardShortcut(.cancelAction) }
                .padding(16).modifier(MacPanelControlPresentation())
        }
    }
}

/// Measure the same localized content and native footer used by the window.
/// A screen-height cap enables scrolling only when the explanation needs it.
@MainActor enum FeatureHelpWindowLayout {
    static func fittingSize(topic: FeatureHelpTopic, language: AppLanguage,
                            width: CGFloat, maximumHeight: CGFloat) -> NSSize {
        let width = max(420, width)
        let content = VStack(spacing: 0) {
            FeatureHelpContent(topic: topic, language: language)
            FeatureHelpFooter(close: {})
        }.environment(\.locale, language.locale)
            .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
            .frame(width: width).fixedSize(horizontal: false, vertical: true)
        let measurement = NSHostingView(rootView: content).fittingSize
        return NSSize(width: width, height: min(ceil(measurement.height), maximumHeight))
    }
}

/// Deterministic, resolution-independent teaching diagrams use native symbols,
/// real typography and localized labels. They never modify the user's data.
struct FeatureHelpVisual: View {
    let topic: FeatureHelpTopic
    let language: AppLanguage
    private func t(_ key: String) -> String { AppStrings.text(key, language: language) }
    private var next: String { language.isRightToLeft ? "chevron.left" : "chevron.right" }
    @ViewBuilder var body: some View {
        if topic != .information {
            illustration.padding(18).frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
                .accessibilityElement(children: .combine)
        }
    }
    @ViewBuilder private var illustration: some View {
        switch topic {
        case .toolbar:
            flow([("house", "Inicio"), ("books.vertical", "Biblioteca"), ("magnifyingglass", "Buscar")])
        case .bibleReading:
            flow([("book.closed", "Libro"), ("list.number", "Capítulo"), ("text.alignleft", "Referencia bíblica")])
        case .referenceTarget:
            flow([("text.book.closed", "Referencia bíblica"), ("scope", "Destino de las referencias")])
        case .imports:
            flow([("doc", "Original"), ("arrow.triangle.2.circlepath", "Convertir"), ("books.vertical", ".libron")])
        case .dictionary:
            flow([("text.cursor", "Palabra"), ("character.book.closed", "Diccionario"), ("text.alignleft", "Definición")])
        case .workspace:
            HStack(spacing: 24) {
                windowTile(split: false)
                Image(systemName: next).foregroundStyle(.secondary)
                windowTile(split: true)
            }.frame(height: 110)
        case .reading:
            HStack(alignment: .bottom, spacing: 16) {
                ForEach([50, 100, 300], id: \.self) { scale in
                    VStack(spacing: 10) {
                        Text(t("Aa")).font(.system(size: Double(scale) * 0.18, weight: .medium))
                            .frame(height: 70, alignment: .bottom)
                        Text("\(scale) %").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }.frame(maxWidth: .infinity)
                }
            }
        case .hoverNotes:
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(t("Texto de ejemplo")).font(.body)
                    Text("1").font(.caption.bold()).foregroundStyle(.tint).baselineOffset(8)
                }.frame(maxWidth: .infinity)
                Image(systemName: "cursorarrow").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 6) {
                    Label { Text(t("Notas y referencias")) } icon: { StudyResourceIcon(kind: .commentary) }.font(.caption.bold())
                    Text(t("Texto de ejemplo")).font(.caption).foregroundStyle(.secondary)
                }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 10))
            }
        case .directory, .library:
            flow([( "folder.badge.plus", "Agregar carpeta"), ("books.vertical", "Biblioteca"), ("folder", "Abrir directorio")])
        case .groups:
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    ForEach(1...3, id: \.self) { number in
                        VStack(spacing: 6) { Image(systemName: "book.closed").font(.largeTitle); Text("\(number)").font(.caption) }
                            .foregroundStyle(number == 2 ? Color.accentColor : Color.secondary).frame(maxWidth: .infinity)
                    }
                }
                HStack { Image(systemName: "chevron.left"); Spacer(); Text(t("Grupos")).font(.caption); Spacer(); Image(systemName: "chevron.right") }
                    .foregroundStyle(.secondary)
            }
        case .synchronization:
            HStack(spacing: 22) {
                step("book.closed", "Referencia bíblica")
                Image(systemName: "link").font(.title2).foregroundStyle(.tint)
                step("book.closed", "Referencia bíblica")
            }
        case .updates:
            flow([("arrow.down.circle", "Descargar actualización"), ("checkmark.shield", "Verificar"), ("power", "Instalar")])
        case .changelog:
            VStack(alignment: .leading, spacing: 12) {
                Label(t("Cambios de esta versión"), systemImage: "chevron.down").font(.headline)
                Label(AppUpdater.shared.installedVersion, systemImage: "list.bullet").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        case .search:
            VStack(spacing: 14) {
                Label(t("Buscar"), systemImage: "magnifyingglass").font(.title3)
                HStack(spacing: 16) {
                    ForEach(["\"…\"", "AND", "OR"], id: \.self) { sample in
                        Text(sample).font(.body.monospaced()).padding(.horizontal, 16).padding(.vertical, 8)
                            .background(.background, in: Capsule())
                    }
                }
            }
        case .topics:
            flow([("tag", "Explorador temático"), ("books.vertical", "Biblioteca"), ("book", "Abrir recurso")])
        case .bibleCopy:
            flow([("book", "Referencia bíblica"), ("doc.text", "Vista previa"), ("doc.on.clipboard", "Copiar")])
        case .navigation:
            HStack(spacing: 16) {
                Image(systemName: "chevron.left"); Image(systemName: "chevron.right")
                VStack(alignment: .leading, spacing: 6) { Text(t("Referencia")).font(.caption).foregroundStyle(.secondary); Text("Ge 1:1").font(.body.monospaced()) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "sidebar.left").font(.title2)
            }.foregroundStyle(.tint)
        case .marks:
            HStack(spacing: 16) {
                Image(systemName: "highlighter").font(.largeTitle).foregroundStyle(.tint)
                Text(t("Texto de ejemplo")).padding(8).background(.yellow.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            }
        case .documents:
            flow([("doc.badge.plus", "Nuevo documento"), ("pencil", "Editar"), ("square.and.arrow.down", "Guardar")])
        case .favorites:
            flow([("book", "Referencia"), ("star", "Favoritos"), ("arrow.uturn.backward", "Abrir")])
        case .maps:
            HStack(spacing: 28) {
                Image(systemName: "map").font(.system(size: 52)).foregroundStyle(.tint)
                Image(systemName: "magnifyingglass.plus").font(.largeTitle).foregroundStyle(.secondary)
                Text("100 %").font(.title3.monospacedDigit())
            }
        case .output:
            flow([("doc.text", "Lectura"), ("square.and.arrow.up", "Exportar"), ("printer", "Imprimir…")])
        case .language:
            HStack(spacing: 16) {
                Image(systemName: "character.bubble").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Español"); Text("English"); Text("العربية")
                }.font(.callout)
                Spacer()
                Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(.tint)
            }
        case .startup:
            flow([("house", "Inicio"), ("clock.arrow.circlepath", "Restaurar las lecturas anteriores"), ("rectangle.stack", "Área de trabajo guardada")])
        case .appearance:
            HStack(spacing: 32) {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 40)).foregroundStyle(.secondary)
                ForEach(AppIconVariant.allCases) { variant in
                    VStack(spacing: 8) {
                        if let image = AppIconPreferences.shared.image(for: variant) {
                            Image(nsImage: image).resizable().frame(width: 44, height: 44)
                        }
                        Text(verbatim: variant.title).font(.caption)
                    }
                }
            }
        case .information: EmptyView()
        }
    }
    private func flow(_ items: [(String, String)]) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ForEach(items.indices, id: \.self) { index in
                if index > 0 { Image(systemName: next).font(.caption).foregroundStyle(.secondary) }
                step(items[index].0, items[index].1)
            }
        }
    }
    private func step(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 10) {
            Group {
                if symbol == "character.book.closed" { StudyResourceIcon(kind: .dictionary, size: 28) }
                else if ["book.closed", "text.book.closed"].contains(symbol), [.bibleReading, .referenceTarget, .bibleCopy, .groups].contains(topic) {
                    StudyResourceIcon(kind: .bible, size: 28)
                } else { Image(systemName: symbol).font(.system(size: 28, weight: .regular)) }
            }.foregroundStyle(.tint).frame(height: 34)
            Text(t(title)).font(.caption).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity)
    }
    private func windowTile(split: Bool) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 9).fill(.background)
                RoundedRectangle(cornerRadius: 9).stroke(.secondary.opacity(0.3), lineWidth: 1)
                if split {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25))
                        .frame(width: (geometry.size.width - 18) / 2, height: geometry.size.height - 16).padding(8)
                    Rectangle().fill(.secondary.opacity(0.25)).frame(width: 1).padding(.vertical, 8).offset(x: geometry.size.width / 2)
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25))
                        .frame(width: geometry.size.width * 0.65, height: geometry.size.height * 0.6).padding(12)
                    Image(systemName: "cursorarrow").foregroundStyle(.tint).offset(x: geometry.size.width * 0.5, y: geometry.size.height * 0.45)
                }
            }
        }.accessibilityHidden(true)
    }
}
