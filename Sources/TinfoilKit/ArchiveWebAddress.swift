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
        guard url.scheme == "zim", url.host == "archive",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.hasPrefix("/") else { return nil }
        // The archive key is exact. URL.path trims a trailing slash from directory entries.
        return String(components.path.dropFirst())
    }
}
