import CoreFoundation
import Foundation
import PDFKit
import SwiftSoup

enum OnlineSourceArchiver {
    private static let maximumBytes = 4 * 1024 * 1024
    private static let maximumText = 250_000
    private static let parallelRequests = 5

    static func capture(_ citations: [OnlineAskCitation], allowMetered: Bool = true) async throws -> [OnlineAskSavedSource] {
        guard !citations.isEmpty else { return [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = allowMetered
        configuration.allowsExpensiveNetworkAccess = allowMetered
        configuration.allowsConstrainedNetworkAccess = allowMetered
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let deadline = ContinuousClock.now + .seconds(30)
        return try await withThrowingTaskGroup(of: (Int, OnlineAskSavedSource).self) { group in
            var saved = Array<OnlineAskSavedSource?>(repeating: nil, count: citations.count)
            var next = 0
            func schedule() {
                let index = next
                let citation = citations[index]
                group.addTask {
                    let snapshot = if ContinuousClock.now < deadline {
                        try await capture(citation, with: session, deadline: deadline)
                    } else {
                        unavailable(citation, note: "Source capture timed out.")
                    }
                    return (index, snapshot)
                }
                next += 1
            }

            for _ in 0..<min(parallelRequests, citations.count) { schedule() }
            for try await (index, source) in group {
                try Task.checkCancellation()
                saved[index] = source
                if next < citations.count { schedule() }
            }
            return saved.compactMap { $0 }
        }
    }

    private static func capture(
        _ citation: OnlineAskCitation, with session: URLSession, deadline: ContinuousClock.Instant
    ) async throws -> OnlineAskSavedSource {
        guard isPublicWebURL(citation.url) else {
            return unavailable(citation, note: "The citation did not link to a public web page.")
        }

        var resolvedURL: URL?
        do {
            var request = URLRequest(url: citation.url)
            request.httpShouldHandleCookies = false
            request.setValue("text/html, text/plain, application/pdf;q=0.9", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, let url = response.url, isPublicWebURL(url) else {
                return unavailable(citation, note: "The source could not be opened.")
            }
            resolvedURL = url
            guard (200...299).contains(response.statusCode), response.statusCode != 206 else {
                return unavailable(citation, resolvedURL: url, note: "The publisher returned HTTP \(response.statusCode).")
            }
            guard allowsStorage(response) else {
                return unavailable(citation, resolvedURL: url, note: "The publisher restricts offline copies.")
            }
            guard response.expectedContentLength <= Int64(maximumBytes) else {
                return unavailable(citation, resolvedURL: url, note: "This source exceeded the offline capture size limit.")
            }
            let mime = response.mimeType?.lowercased()
            guard mime == "text/html" || mime == "application/xhtml+xml" || mime == "text/plain" || mime == "application/pdf" else {
                return unavailable(citation, resolvedURL: url, note: "This source did not provide a supported text page or PDF.")
            }
            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(Int(response.expectedContentLength))
            }
            var truncated = false
            for try await byte in bytes {
                if data.count == maximumBytes || ContinuousClock.now >= deadline {
                    truncated = true
                    break
                }
                data.append(byte)
            }
            try Task.checkCancellation()

            let snapshot: Snapshot
            if mime == "application/pdf" {
                guard !truncated else {
                    return unavailable(citation, resolvedURL: url, note: "The complete PDF could not be captured.")
                }
                snapshot = snapshotPDF(data)
            } else {
                // A truncated HTML document may omit applicable publisher controls.
                guard !truncated else {
                    return unavailable(citation, resolvedURL: url, note: "The complete web page could not be captured.")
                }
                let contents = decodeText(data, charset: response.textEncodingName)
                snapshot = mime == "text/plain" ? snapshotText(contents) : try snapshotHTML(contents)
            }
            let attributed = citation.title.isEmpty
                ? OnlineAskCitation(url: citation.url, title: snapshot.title ?? url.absoluteString, excerpt: citation.excerpt)
                : citation
            return OnlineAskSavedSource(citation: attributed, resolvedURL: url, text: snapshot.text, note: snapshot.note)
        } catch {
            try Task.checkCancellation()
            return unavailable(citation, resolvedURL: resolvedURL, note: "The publisher’s content could not be saved for offline reading.")
        }
    }

    private static func unavailable(
        _ citation: OnlineAskCitation, resolvedURL: URL? = nil, note: String
    ) -> OnlineAskSavedSource {
        OnlineAskSavedSource(citation: citation, resolvedURL: resolvedURL, text: nil, note: note)
    }

    static func isPublicWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil || url.port == (scheme == "https" ? 443 : 80) else {
            return false
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, let suffix = labels.last, suffix.first?.isLetter == true,
              !["local", "localdomain", "localhost", "test", "example", "invalid", "internal", "lan", "home", "onion"].contains(suffix),
              !host.hasSuffix(".home.arpa"), !host.hasSuffix(".in-addr.arpa"), !host.hasSuffix(".ip6.arpa") else {
            return false
        }
        return labels.allSatisfy { label in
            guard let first = label.first, let last = label.last,
                  first != "-", last != "-", label.utf8.count <= 63 else { return false }
            return label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    static func allowsStorage(_ response: HTTPURLResponse) -> Bool {
        let cache = directives(response.value(forHTTPHeaderField: "Cache-Control") ?? "")
        return cache.isDisjoint(with: ["no-store", "no-cache"])
            && allowsRobots(response.value(forHTTPHeaderField: "X-Robots-Tag") ?? "")
    }

    private static func directives(_ value: String) -> Set<String> {
        Set(value.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init))
    }

    private static func allowsRobots(_ robots: String) -> Bool {
        directives(robots).isDisjoint(with: ["noarchive", "nocache", "nosnippet", "noai"])
            && robots.range(of: #"(?i)max-snippet\s*:\s*0(?:\D|$)"#, options: .regularExpression) == nil
    }

    private static func decodeText(_ data: Data, charset: String?) -> String {
        if let charset {
            let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let string = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return string
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    struct Snapshot {
        let text: String?
        let note: String?
        var title: String? = nil
    }

    static func snapshotHTML(_ source: String) throws -> Snapshot {
        let document = try SwiftSoup.parse(source)
        for meta in try document.select("meta[name]").array() {
            let name = try meta.attr("name").lowercased()
            if ["robots", "googlebot", "bingbot", "claudebot", "gptbot"].contains(name),
               !allowsRobots(try meta.attr("content")) {
                return Snapshot(text: nil, note: "The publisher restricts offline copies.")
            }
        }
        try document.select("script, style, noscript, iframe, template, nav, footer, aside, form, [hidden], [aria-hidden=true]").remove()
        let content = try document.select("main, [role=main]").first()
            ?? document.select("article").first() ?? document.body()
        var snapshot = snapshotText(try content?.text() ?? "")
        let title = try document.title().trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { snapshot.title = String(title.prefix(240)) }
        return snapshot
    }

    private static func snapshotPDF(_ data: Data) -> Snapshot {
        guard let document = PDFDocument(data: data), !document.isLocked, document.allowsCopying else {
            return Snapshot(text: nil, note: "The PDF is locked or does not allow text copying.")
        }
        var text = ""
        let maximumPages = min(document.pageCount, 100)
        for page in 0..<maximumPages {
            if Task.isCancelled || text.count > maximumText { break }
            if let body = autoreleasepool(invoking: { document.page(at: page)?.string }), !body.isEmpty {
                text += body.prefix(maximumText + 1)
                text += "\n\n"
            }
        }
        let snapshot = snapshotText(text)
        if snapshot.note == nil, document.pageCount > maximumPages {
            return Snapshot(text: snapshot.text, note: "Saved text from the first \(maximumPages) pages.")
        }
        return snapshot
    }

    static func snapshotText(_ value: String) -> Snapshot {
        let span = value.prefix(maximumText + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !span.isEmpty else {
            return Snapshot(text: nil, note: "The source did not contain extractable text.")
        }
        if span.count > maximumText {
            return Snapshot(text: String(span.prefix(maximumText)), note: "Saved text was shortened to fit the offline capture limit.")
        }
        return Snapshot(text: span, note: nil)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let isTLS = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            completionHandler(isTLS ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let target = request.url, isPublicWebURL(target),
                  response.url?.scheme?.lowercased() != "https" || target.scheme?.lowercased() == "https" else {
                completionHandler(nil)
                return
            }
            // Build a clean request so credentials and cookies never cross redirects.
            var clean = URLRequest(url: target)
            clean.httpShouldHandleCookies = false
            clean.setValue("text/html, text/plain, application/pdf;q=0.9", forHTTPHeaderField: "Accept")
            completionHandler(clean)
        }
    }
}
