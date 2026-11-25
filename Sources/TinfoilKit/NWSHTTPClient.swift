import Foundation

enum NWSHTTPClient {
    struct Response: Sendable {
        let body: Data?
        let checkedAt: Date
        let expiresAt: Date?
        let etag: String?
        let lastModified: String?
    }

    static func fetch(
        _ endpoint: URL, maximumBytes: Int, allowMetered: Bool, etag: String? = nil, lastModified: String? = nil
    ) async throws -> Response {
        guard endpoint.scheme == "https", endpoint.host == "api.weather.gov" else { throw ResponseError.invalid }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsCellularAccess = allowMetered
        configuration.allowsExpensiveNetworkAccess = allowMetered
        configuration.allowsConstrainedNetworkAccess = allowMetered
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        request.setValue("TinfoilKit-iOS (+https://github.com/scottleibrand/TinFoilKit-iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")

        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse, response.url?.scheme == "https",
              response.url?.host == endpoint.host else { throw ResponseError.invalid }
        let body: Data?
        switch response.statusCode {
        case 304:
            body = nil
        case 200:
            guard response.expectedContentLength <= Int64(maximumBytes) else { throw ResponseError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw ResponseError.tooLarge }
                data.append(byte)
            }
            body = data
        default:
            throw ResponseError.httpStatus(response.statusCode)
        }
        return Response(body: body, checkedAt: .now, expiresAt: httpDate(response.value(forHTTPHeaderField: "Expires")),
                        etag: response.value(forHTTPHeaderField: "ETag"),
                        lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
    }

    private static func httpDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: text)
    }

    enum ResponseError: LocalizedError {
        case invalid, tooLarge, httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalid: "The National Weather Service returned an unexpected response."
            case .tooLarge: "The National Weather Service response exceeded the download limit."
            case let .httpStatus(status): "The National Weather Service returned HTTP \(status)."
            }
        }
    }
}
