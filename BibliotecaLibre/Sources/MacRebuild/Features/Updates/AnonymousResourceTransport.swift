import Foundation
import LibronixCore

protocol ResourceDownloadTransport: Sendable {
    func fetch(_ url: URL, maximumBytes: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}
struct AnonymousResourceTransport: ResourceDownloadTransport {
    func fetch(_ url: URL, maximumBytes: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard ResourceCollectionFile.https(url) else { throw LibronError.invalid("Resource downloads require HTTPS") }
        if let id = try IcedrivePublicDownload.fileID(url) {
            let metadata = try await fetchDirect(url, maximumBytes: 65_536) { _ in }
            defer { try? FileManager.default.removeItem(at: metadata) }
            let address = try IcedrivePublicDownload.address(from: Data(contentsOf: metadata), fileID: id, maximumBytes: maximumBytes)
            try Task.checkCancellation()
            return try await fetchDirect(address, maximumBytes: maximumBytes, progress: progress)
        }
        return try await fetchDirect(Self.directURL(url), maximumBytes: maximumBytes, progress: progress)
    }

    private func fetchDirect(_ url: URL, maximumBytes: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = ResourceTransferDelegate(maximumBytes: maximumBytes, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url)
                delegate.start(task, continuation: continuation)
            }
        } onCancel: { delegate.cancel() }
    }
    /// Public Drive blob links use the browser download endpoint, without OAuth.
    static func directURL(_ url: URL) -> URL {
        guard url.host == "drive.google.com" else { return url }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 3, parts[0] == "file", parts[1] == "d",
              parts[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return url }
        var result = URLComponents(string: "https://drive.google.com/uc")!
        result.queryItems = [URLQueryItem(name: "export", value: "download"), URLQueryItem(name: "id", value: String(parts[2]))]
        if let resourceKey = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "resourcekey" }) {
            result.queryItems?.append(resourceKey)
        }
        return result.url!
    }
}
private final class ResourceTransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int64
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, any Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var result: Result<URL, any Error>?
    init(maximumBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.maximumBytes = maximumBytes; self.progress = progress
    }
    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<URL, any Error>) {
        lock.lock(); self.task = task; self.continuation = continuation; let stop = cancelled; lock.unlock()
        if stop { task.cancel() }
        task.resume()
    }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(ResourceCollectionFile.https) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            lock.lock(); result = .failure(LibronError.invalid("Resource download exceeds size limit")); lock.unlock()
            downloadTask.cancel(); return
        }
        if totalBytesExpectedToWrite > 0 { progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  response.url.map(ResourceCollectionFile.https) == true else { throw LibronError.invalid("El servidor no permite descargar el recurso sin sesión.") }
            guard response.mimeType != "text/html", response.mimeType != "application/xhtml+xml" else {
                throw LibronError.invalid("El enlace devolvió una página web. Comprueba el permiso de descarga pública.")
            }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= maximumBytes else { throw LibronError.invalid("Invalid resource download size") }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("libron-download-" + UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: target)
            lock.lock(); result = .success(target); lock.unlock()
        } catch { lock.lock(); result = .failure(error); lock.unlock() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let continuation = continuation; self.continuation = nil
        let final = result ?? .failure(error ?? LibronError.invalid("Resource transfer did not finish"))
        lock.unlock()
        continuation?.resume(with: final)
    }
}
