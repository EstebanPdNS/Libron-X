import AppKit
import LibronixCore

/// Native edits are a separate RTF representation. Reading HTML uses the inert
/// portable projection and cannot load remote images, scripts or stylesheets.
enum NoteRichTextCodec {
    static func decode(_ data: Data) throws -> NSAttributedString {
        guard data.count <= MetadataXMLReader.maximumFileBytes,
              data.starts(with: Data("{\\rtf".utf8)),
              let value = NSAttributedString(rtf: data, documentAttributes: nil) else {
            throw PersonalStateError.invalid("No se pudo abrir el texto enriquecido de la nota. Se conserva su representación original.")
        }
        return value
    }

    static func encode(_ text: NSAttributedString) throws -> Data {
        let data = try text.data(from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        guard data.count <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
        // Do not accept a serializer that silently loses visible text.
        guard try decode(data).string == text.string else {
            throw PersonalStateError.invalid("No se pudo conservar el contenido de la nota al guardarlo.")
        }
        return data
    }

    @MainActor static func attributed(_ note: StudyNote) throws -> NSAttributedString {
        if let data = note.editedRTF { return try decode(data) }
        return source(note)
    }

    @MainActor static func source(_ note: StudyNote) -> NSAttributedString {
        let spans = note.sourceContentType == "text/html" ? NoteHTMLProjection.spans(note.sourceBody) : [NoteTextSpan(text: note.sourceBody)]
        let result = NSMutableAttributedString(string: "")
        for span in spans {
            var font = NSFont.systemFont(ofSize: 16)
            if span.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if span.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
            if span.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if span.strikeout { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let link = span.reference.flatMap(referenceURL) ?? span.hyperlink.flatMap(webURL)
            if let link { attributes[.link] = link; attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: span.text, attributes: attributes))
        }
        return result
    }

    static func referenceURL(_ reference: String) -> URL? {
        guard !reference.isEmpty, reference.utf8.count <= 4_096 else { return nil }
        var components = URLComponents()
        components.scheme = "libronx-reference"
        components.queryItems = [URLQueryItem(name: "target", value: reference)]
        return components.url
    }

    static func referenceTarget(_ value: Any?) -> String? {
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let url, url.scheme == "libronx-reference",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first(where: { $0.name == "target" })?.value
    }

    static func webURL(_ target: String) -> URL? {
        guard target.utf8.count <= 4_096, let url = URL(string: target),
              ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    static func projection(_ data: Data) throws -> (text: String, links: [BibleReferenceSourceLink]) {
        let value = try decode(data)
        var links: [BibleReferenceSourceLink] = []
        value.enumerateAttribute(.link, in: NSRange(location: 0, length: value.length)) { target, range, _ in
            guard let reference = referenceTarget(target), range.length > 0 else { return }
            links.append(.init(range: .init(location: range.location, length: range.length), target: reference))
        }
        return (value.string, links)
    }

    static func hasUnsupportedHTMLObjects(_ note: StudyNote) -> Bool {
        guard note.sourceContentType == "text/html" else { return false }
        return note.sourceBody.range(of: #"<\s*(img|table|object|iframe|video|audio|svg)\b"#,
                                     options: [.regularExpression, .caseInsensitive]) != nil
    }
}
