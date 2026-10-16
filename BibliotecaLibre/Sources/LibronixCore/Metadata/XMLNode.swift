import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A parsed XML representation preserves ordered mixed content, significant
/// whitespace and attributes. It contains data only, never executable scripts.
public struct XMLNode: Codable, Hashable, Sendable {
    public let name: String
    public let attributes: [String: String]
    public let content: [XMLContent]

    public init(name: String, attributes: [String: String] = [:], content: [XMLContent] = []) {
        self.name = name
        self.attributes = attributes
        self.content = content
    }

    public var children: [XMLNode] {
        content.compactMap { if case let .element(node) = $0 { node } else { nil } }
    }

    public var text: String {
        content.map {
            switch $0 {
            case let .text(text), let .cdata(text): text
            case let .element(node): node.text
            case .comment: ""
            }
        }.joined()
    }

    public var comments: [String] {
        content.flatMap { item -> [String] in
            switch item {
            case let .comment(comment): return [comment]
            case let .element(node): return node.comments
            default: return []
            }
        }
    }

    public func child(named name: String) -> XMLNode? {
        children.first { $0.name == name }
    }

    public func children(named name: String) -> [XMLNode] {
        children.filter { $0.name == name }
    }
}

public indirect enum XMLContent: Codable, Hashable, Sendable {
    case element(XMLNode)
    case text(String)
    case cdata(String)
    case comment(String)
}

public enum MetadataReadError: Error, LocalizedError, Sendable {
    case notDirectory
    case tooManyFiles
    case fileTooLarge
    case opaqueContainer
    case unsupportedDocument(String)
    case prohibitedDeclaration
    case structuralLimit
    case malformedXML(line: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notDirectory: "La ruta de metadatos no es una carpeta."
        case .tooManyFiles: "La carpeta supera el límite de 100.000 archivos de metadatos."
        case .fileTooLarge: "El documento supera el límite de 16 MB."
        case .opaqueContainer: "El contenedor LTES no tiene un decodificador de metadatos disponible."
        case let .unsupportedDocument(name): "Tipo de documento XML no soportado: \(name)."
        case .prohibitedDeclaration: "Los documentos de metadatos no admiten DTD ni entidades declaradas."
        case .structuralLimit: "El XML supera los límites de estructura o texto del importador."
        case let .malformedXML(line, message): "XML inválido en línea \(line): \(message)"
        }
    }
}

public enum MetadataXMLReader {
    public static let maximumFileBytes = 16 * 1024 * 1024

    public static func parse(_ data: Data) throws -> XMLNode {
        guard data.count <= maximumFileBytes else { throw MetadataReadError.fileTooLarge }
        if data.starts(with: [0x4c, 0x54, 0x45, 0x53]) { throw MetadataReadError.opaqueContainer }
        // XMLParser supports legacy declared encodings. Preflight also catches
        // UTF-16 DTD declarations before libxml can expand their entities.
        let encodings: [String.Encoding] = [.isoLatin1, .utf16LittleEndian, .utf16BigEndian]
        if encodings.contains(where: {
            String(data: data, encoding: $0)?.contains("<!DOCTYPE") == true
        }) { throw MetadataReadError.prohibitedDeclaration }
        let delegate = TreeDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            if let error = delegate.failure { throw error }
            throw MetadataReadError.malformedXML(line: parser.lineNumber,
                message: parser.parserError?.localizedDescription ?? "Documento sin raíz")
        }
        if let error = delegate.failure { throw error }
        return root
    }
}

private final class TreeDelegate: NSObject, XMLParserDelegate {
    private struct Frame {
        var name: String
        var attributes: [String: String]
        var content: [XMLContent] = []
    }
    private var frames: [Frame] = []
    private var nodeCount = 0
    private var characterCount = 0
    private var contentCount = 0
    var root: XMLNode?
    var failure: MetadataReadError?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        nodeCount += 1
        guard nodeCount <= 100_000, frames.count < 128, attributeDict.count <= 1_024 else {
            fail(.structuralLimit, parser)
            return
        }
        frames.append(Frame(name: elementName, attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard let frame = frames.popLast() else { return }
        let node = XMLNode(name: frame.name, attributes: frame.attributes, content: frame.content)
        if frames.isEmpty { root = node }
        else { append(.element(node)) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard admit(string, parser) else { return }
        appendText(string)
    }

    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
        guard admit(whitespaceString, parser) else { return }
        appendText(whitespaceString)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8), admit(string, parser) else { return }
        append(.cdata(string))
    }

    func parser(_ parser: XMLParser, foundComment comment: String) {
        guard admit(comment, parser) else { return }
        append(.comment(comment))
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail(.prohibitedDeclaration, parser)
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                publicID: String?, systemID: String?) {
        fail(.prohibitedDeclaration, parser)
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        fail(.prohibitedDeclaration, parser)
        return nil
    }

    private func admit(_ text: String, _ parser: XMLParser) -> Bool {
        characterCount += text.utf8.count
        if characterCount > MetadataXMLReader.maximumFileBytes {
            fail(.structuralLimit, parser)
            return false
        }
        return true
    }

    private func append(_ item: XMLContent) {
        guard !frames.isEmpty else { return }
        contentCount += 1
        guard contentCount <= 200_000 else {
            if failure == nil { failure = .structuralLimit }
            return
        }
        frames[frames.count - 1].content.append(item)
    }

    private func appendText(_ text: String) {
        guard !frames.isEmpty else { return }
        let index = frames.count - 1
        if case let .text(previous)? = frames[index].content.last, previous.utf8.count < 4_096 {
            frames[index].content[frames[index].content.count - 1] = .text(previous + text)
        } else { append(.text(text)) }
    }

    private func fail(_ error: MetadataReadError, _ parser: XMLParser) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }
}
