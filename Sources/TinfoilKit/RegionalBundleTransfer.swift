import Foundation

struct RegionalBundleResponse {
    let offset: Int64
    let validator: String?

    init(_ response: HTTPURLResponse, total: Int64?, limit: Int64, requestedOffset: Int64,
         requestedValidator: String?) throws {
        guard let url = response.url, RegionalBundleManifest.isHTTPS(url),
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            throw RegionalBundleDownloadError.response
        }
        let contentLength: Int64
        if let length = response.value(forHTTPHeaderField: "Content-Length") {
            guard let count = Int64(length), count >= 0 else { throw RegionalBundleDownloadError.size }
            contentLength = count
        } else {
            contentLength = response.expectedContentLength
        }
        validator = Self.strongETag(response.value(forHTTPHeaderField: "ETag"))
        switch response.statusCode {
        case 200:
            guard response.value(forHTTPHeaderField: "Content-Range") == nil else {
                throw RegionalBundleDownloadError.response
            }
            offset = 0
        case 206:
            guard let total, requestedOffset > 0, requestedOffset < total,
                  let requestedValidator, validator == requestedValidator,
                  response.value(forHTTPHeaderField: "Content-Range")
                    == "bytes \(requestedOffset)-\(total - 1)/\(total)" else {
                throw RegionalBundleDownloadError.response
            }
            offset = requestedOffset
        default:
            throw RegionalBundleDownloadError.http(response.statusCode)
        }
        if contentLength >= 0 {
            guard contentLength <= limit - offset,
                  total == nil || contentLength == total.map({ $0 - offset }) else {
                throw RegionalBundleDownloadError.size
            }
        }
    }

    private static func strongETag(_ text: String?) -> String? {
        guard let text, text.utf8.count >= 2, text.utf8.first == 34, text.utf8.last == 34,
              text.utf8.dropFirst().dropLast().allSatisfy({ $0 == 33 || (35...126).contains($0) }) else { return nil }
        return text
    }

    static func redirect(_ request: URLRequest, preserving original: URLRequest?) -> URLRequest? {
        guard let url = request.url, RegionalBundleManifest.isHTTPS(url) else { return nil }
        var redirected = request
        for header in ["Accept-Encoding", "Range", "If-Range"] {
            redirected.setValue(original?.value(forHTTPHeaderField: header), forHTTPHeaderField: header)
        }
        return redirected
    }
}

final class RegionalBundleTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Outcome: Sendable {
        let validator: String?
        let error: Error?
    }

    private let file: URL
    private let limit: Int64
    private let size: Int64?
    private let offset: Int64
    private let progress: @Sendable (Int64) -> Void
    // Delegate state is used on the session's serial delegate queue. The lock also covers starting and cancelling its task.
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var completion: CheckedContinuation<Outcome, Never>?
    private var writer: FileHandle?
    private var received: Int64
    private var validator: String?
    private var lastReport: Int64
    private var failure: Error?

    private init(file: URL, limit: Int64, size: Int64?, offset: Int64, validator: String?,
                 progress: @escaping @Sendable (Int64) -> Void) {
        self.file = file
        self.limit = limit
        self.size = size
        self.offset = offset
        self.validator = offset > 0 ? validator : nil
        self.progress = progress
        received = offset
        lastReport = offset
    }

    static func receive(_ url: URL, to file: URL, limit: Int64, size: Int64?, offset: Int64,
                        validator: String?, cellular: Bool,
                        progress: @escaping @Sendable (Int64) -> Void) async -> Outcome {
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        let receiver = RegionalBundleTransfer(file: file, limit: limit, size: size, offset: offset,
                                              validator: validator, progress: progress)
        let transferRequest = request
        return await withTaskCancellationHandler {
            await withCheckedContinuation { receiver.start(transferRequest, cellular: cellular, completion: $0) }
        } onCancel: {
            receiver.cancel()
        }
    }

    private func start(_ request: URLRequest, cellular: Bool, completion: CheckedContinuation<Outcome, Never>) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = cellular
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        let started = lock.withLock {
            guard !cancelled else { return false }
            self.completion = completion
            self.task = task
            return true
        }
        if started {
            task.resume()
        } else {
            session.invalidateAndCancel()
            completion.resume(returning: Outcome(validator: validator, error: CancellationError()))
        }
    }

    private func cancel() {
        let current = lock.withLock {
            cancelled = true
            return task
        }
        current?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(RegionalBundleResponse.redirect(request, preserving: task.originalRequest))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw RegionalBundleDownloadError.response }
            let headers = try RegionalBundleResponse(response, total: size, limit: limit, requestedOffset: offset,
                                                     requestedValidator: validator)
            let files = FileManager.default
            if !files.fileExists(atPath: file.path),
               !files.createFile(atPath: file.path, contents: nil) {
                throw RegionalBundleDownloadError.storage
            }
            let output = try FileHandle(forWritingTo: file)
            writer = output
            if headers.offset == 0 { try output.truncate(atOffset: 0) }
            try output.seek(toOffset: UInt64(headers.offset))
            received = headers.offset
            lastReport = received
            validator = headers.validator
            progress(received)
            completionHandler(.allow)
        } catch RegionalBundleDownloadError.http(let status) {
            failure = RegionalBundleDownloadError.http(status)
            completionHandler(.cancel)
        } catch {
            failure = error
            validator = nil
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            guard let writer, Int64(data.count) <= limit - received else { throw RegionalBundleDownloadError.size }
            try writer.write(contentsOf: data)
            received += Int64(data.count)
            if received - lastReport >= 256 * 1024 {
                lastReport = received
                progress(received)
            }
        } catch {
            failure = error
            validator = nil
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do {
            try writer?.synchronize()
            try writer?.close()
        } catch {
            failure = error
            validator = nil
        }
        writer = nil
        let passed = received > 0 && (size == nil || received == size)
        let result = failure ?? error ?? (passed ? nil : RegionalBundleDownloadError.incomplete)
        if result == nil { progress(received) }
        let continuation = lock.withLock {
            self.task = nil
            defer { completion = nil }
            return completion
        }
        session.finishTasksAndInvalidate()
        continuation?.resume(returning: Outcome(validator: validator, error: result))
    }
}
