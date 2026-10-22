import Foundation
import LibronixCore

/// Resolves a public file ID on each transfer; expiring CDN addresses never enter codes or catalogs.
/// Uses Icedrive's public web download endpoint without account credentials or cookies.
enum IcedrivePublicDownload {
    private static let prefix = "/v3/webapp/download-multi&items=file-"
    private static let suffix = "&public=1"

    static func fileID(_ url: URL) throws -> Int64? {
        guard url.host?.lowercased() == "apis.icedrive.net" else { return nil }
        guard ResourceCollectionFile.https(url), url.port == nil || url.port == 443,
              url.query == nil, url.fragment == nil,
              url.path.hasPrefix(prefix), url.path.hasSuffix(suffix) else {
            throw LibronError.invalid("Invalid Icedrive public download address")
        }
        let value = url.path.dropFirst(prefix.count).dropLast(suffix.count)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let id = Int64(value), id > 0 else {
            throw LibronError.invalid("Invalid Icedrive public file ID")
        }
        return id
    }

    private struct Response: Decodable {
        struct File: Decodable {
            let id: Int64
            let filesize: Int64
            let url: URL
        }
        let error: Bool
        let urls: [File]?
    }

    static func address(from data: Data, fileID: Int64, maximumBytes: Int64) throws -> URL {
        guard data.count <= 65_536 else { throw LibronError.invalid("Icedrive response exceeds size limit") }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard !response.error, let files = response.urls, files.count == 1 else {
            throw LibronError.invalid("Icedrive no permite descargar este archivo públicamente. Comprueba el enlace y el límite de transferencia.")
        }
        let file = files[0]
        guard file.id == fileID, file.filesize > 0, file.filesize <= maximumBytes,
              ResourceCollectionFile.https(file.url), file.url.port == nil || file.url.port == 443,
              let host = file.url.host?.lowercased(), host.hasSuffix(".icedrive.io"),
              file.url.path == "/download", file.url.fragment == nil,
              URLComponents(url: file.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "p" && !($0.value ?? "").isEmpty }) == true else {
            throw LibronError.invalid("Invalid Icedrive download response")
        }
        return file.url
    }
}
