import AppKit
import SwiftUI
import LibronixCore

/// A shared book silhouette; only the cover mark changes between resource kinds.
enum StudyResourceKind: CaseIterable, Hashable, Sendable {
    case bible, dictionary, commentary
    @MainActor static func identifying(_ reader: ReaderSession) -> Self? {
        if reader.isCommentary { return .commentary }
        if reader.isDictionary { return .dictionary }
        if LibronMetadata.deriving(reader.resource).resourceType == "Biblia" { return .bible }
        return nil
    }
    @MainActor var image: NSImage { Self.images[self]! }
    @MainActor private static let images: [Self: NSImage] = Dictionary(uniqueKeysWithValues: allCases.map { kind in
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()
            let cover = NSBezierPath(roundedRect: NSRect(x: 5, y: 4.5, width: 12, height: 14), xRadius: 1.6, yRadius: 1.6)
            cover.lineWidth = 1.15; cover.stroke()
            let spine = NSBezierPath()
            spine.move(to: NSPoint(x: 5, y: 18.5)); spine.line(to: NSPoint(x: 3.5, y: 18.5))
            spine.curve(to: NSPoint(x: 2, y: 17), controlPoint1: NSPoint(x: 2.5, y: 18.5), controlPoint2: NSPoint(x: 2, y: 18))
            spine.line(to: NSPoint(x: 2, y: 3))
            spine.curve(to: NSPoint(x: 3.5, y: 1.5), controlPoint1: NSPoint(x: 2, y: 2), controlPoint2: NSPoint(x: 2.5, y: 1.5))
            spine.line(to: NSPoint(x: 17, y: 1.5)); spine.lineWidth = 1.15; spine.stroke()
            let mark = NSBezierPath(); mark.lineWidth = 1.05; mark.lineCapStyle = .round; mark.lineJoinStyle = .round
            switch kind {
            case .bible:
                mark.move(to: NSPoint(x: 11, y: 8.5)); mark.line(to: NSPoint(x: 11, y: 14.5))
                mark.move(to: NSPoint(x: 9, y: 12.5)); mark.line(to: NSPoint(x: 13, y: 12.5))
            case .dictionary:
                mark.move(to: NSPoint(x: 8.8, y: 8.8)); mark.line(to: NSPoint(x: 11, y: 14.2)); mark.line(to: NSPoint(x: 13.2, y: 8.8))
                mark.move(to: NSPoint(x: 9.6, y: 10.7)); mark.line(to: NSPoint(x: 12.4, y: 10.7))
            case .commentary:
                for y in [13.8, 11.5, 9.2] {
                    mark.move(to: NSPoint(x: 8.2, y: y)); mark.line(to: NSPoint(x: y == 9.2 ? 12 : 13.8, y: y))
                }
            }
            mark.stroke(); return true
        }
        image.isTemplate = true
        return (kind, image)
    })
}

struct StudyResourceIcon: View {
    let kind: StudyResourceKind
    var size: CGFloat = 20
    var body: some View { Image(nsImage: kind.image).resizable().frame(width: size, height: size).accessibilityHidden(true) }
}
struct StudyResourceLabel: View {
    let title: String
    let kind: StudyResourceKind
    var menu = false
    var body: some View {
        Label { Text(L(title)) } icon: { StudyResourceIcon(kind: kind) }
            .labelStyle(.iconOnly).accessibilityLabel(L(title))
            .padding(.leading, menu ? 6 : 0).padding(.trailing, menu ? 4 : 0)
            .featureHelpTarget(.resolve(labels: [L(title)], windowTitle: "", language: AppLanguage.saved()))
    }
}
