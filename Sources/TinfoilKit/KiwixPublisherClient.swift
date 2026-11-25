import Foundation

enum KiwixPublisherClient {
    static let resultLimit = 20
    static let catalogueURL = URL(string: "https://opds.library.kiwix.org/catalog/v2/entries")!
    private static let maximumCatalogBytes = 512 * 1024

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }()

    static func search(_ input: String) async throws -> [KiwixCatalog.Book] {
        let request = try searchRequest(input)
        let data = try await receive(request, limit: maximumCatalogBytes)
        return try KiwixCatalog.parse(data)
    }

    static func metadata(for book: KiwixCatalog.Book) async throws -> KiwixMetalink {
        var request = URLRequest(url: book.metalinkURL)
        request.setValue("application/metalink4+xml, application/xml;q=0.8", forHTTPHeaderField: "Accept")
        let data = try await receive(request, limit: KiwixMetalink.maximumResponseBytes)
        return try KiwixMetalink.parse(data, expectedFilename: book.archiveURL.lastPathComponent)
    }

    static func searchRequest(_ input: String) throws -> URLRequest {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...200).contains(query.utf8.count), query.contains(where: { $0.isLetter || $0.isNumber }),
              query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ClientError.invalidQuery
        }
        var url = URLComponents(url: catalogueURL, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: String(resultLimit))]
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: url.url!)
        request.setValue("application/atom+xml, application/xml;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    private static func receive(_ request: URLRequest, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let reply = response as? HTTPURLResponse, reply.url == request.url else {
            throw ClientError.invalidReply
        }
        guard reply.statusCode == 200 else { throw ClientError.http(reply.statusCode) }
        guard reply.expectedContentLength <= Int64(limit) else { throw ClientError.tooLarge }
        var data = Data()
        if reply.expectedContentLength > 0 { data.reserveCapacity(Int(reply.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < limit else { throw ClientError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private enum ClientError: LocalizedError {
        case invalidQuery, invalidReply, tooLarge, http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidQuery: "Enter a short book title or topic."
            case .invalidReply: "Kiwix returned an unexpected response."
            case .tooLarge: "The Kiwix response exceeded the reading limit."
            case .http(let status): "Kiwix returned HTTP \(status)."
            }
        }
    }
}
