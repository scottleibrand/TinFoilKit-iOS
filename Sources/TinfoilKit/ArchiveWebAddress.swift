import Foundation

enum ArchiveWebAddress {
    static func url(for path: String, fragment: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "zim"
        components.host = "archive"
        components.path = "/" + path
        components.fragment = fragment
        return components.url
    }

    static func path(in url: URL) -> String? {
        // URL.path trims a trailing slash. A canonical bookmark stores its exact key in the path.
        archiveComponents(in: url).map { String($0.path.dropFirst()) }
    }

    static func candidates(in url: URL) -> [String] {
        guard let components = archiveComponents(in: url) else { return [] }
        let path = String(components.path.dropFirst())
        guard let query = components.percentEncodedQuery else { return [path] }
        return [path + "?" + query, path]
    }

    static func canonicalURL(for path: String, relativeTo request: URL) -> URL? {
        guard let components = archiveComponents(in: request) else { return nil }
        return url(for: path, fragment: components.fragment)
    }

    private static func archiveComponents(in url: URL) -> URLComponents? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme == "zim", components.percentEncodedHost == "archive",
              components.user == nil, components.password == nil,
              components.port == nil, components.rangeOfPort == nil,
              components.path.hasPrefix("/") else { return nil }
        return components
    }
}
