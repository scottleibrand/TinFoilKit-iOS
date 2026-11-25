import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum KiwixCatalog {
    struct Book: Identifiable, Sendable {
        let id: UUID
        let title: String
        let summary: String
        let language: String
        let updated: String
        let creator: String
        let estimatedBytes: Int64
        let metalinkURL: URL
        let readerURL: URL?

        var archiveURL: URL { metalinkURL.deletingPathExtension() }
    }

    static func parse(_ data: Data) throws -> [Book] {
        guard data.count <= 512 * 1024 else { throw ParseError.tooLarge }
        guard !data.contains(0), var xml = String(data: data, encoding: .utf8),
              xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw ParseError.invalidFeed }
        if xml.hasPrefix("\u{FEFF}") { xml.removeFirst() }
        // Keep XMLParser in the UTF-8 encoding used by the DTD preflight above.
        if xml.hasPrefix("<?xml"), let next = xml.utf8.dropFirst(5).first, [9, 10, 13, 32].contains(next) {
            let utf8Declaration = #"^<\?xml\s+version\s*=\s*(?:"1\.0"|'1\.0')(?:\s+encoding\s*=\s*(?:"[Uu][Tt][Ff]-8"|'[Uu][Tt][Ff]-8'))?(?:\s+standalone\s*=\s*(?:"(?:yes|no)"|'(?:yes|no)'))?\s*\?>"#
            guard xml.range(of: utf8Declaration, options: .regularExpression) != nil else {
                throw ParseError.invalidFeed
            }
        }
        let collector = AtomCollector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), parser.parserError == nil, collector.sawFeed, collector.error == nil else {
            throw collector.error ?? ParseError.invalidFeed
        }
        return collector.books
    }

    private enum ParseError: LocalizedError {
        case invalidFeed, tooLarge, tooManyEntries

        var errorDescription: String? {
            switch self {
            case .invalidFeed: "Kiwix returned an invalid catalog page."
            case .tooLarge: "The Kiwix catalog page exceeded the size limit."
            case .tooManyEntries: "The Kiwix catalog page contained too many entries."
            }
        }
    }

    private final class AtomCollector: NSObject, XMLParserDelegate {
        struct Element: Equatable {
            let name: String
            let namespace: String?

            func isAtom(_ name: String) -> Bool {
                self.name == name && namespace == "http://www.w3.org/2005/Atom"
            }
        }

        enum Field: String {
            case id, title, summary, language, updated, creator
        }

        struct Capture {
            let field: Field
            let depth: Int
            var text = ""
        }

        struct Entry {
            var text: [Field: String] = [:]
            var download: (url: URL, estimatedBytes: Int64)?
            var readerURL: URL?
        }

        private let date = ISO8601DateFormatter()
        private let fractionalDate: ISO8601DateFormatter = {
            let date = ISO8601DateFormatter()
            date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return date
        }()
        private var elements: [Element] = []
        private var entry: Entry?
        private var capture: Capture?
        private var entryCount = 0
        private var ids: Set<UUID> = []
        private(set) var sawFeed = false
        private(set) var books: [Book] = []
        private(set) var error: ParseError?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            let element = Element(name: elementName, namespace: namespaceURI)
            elements.append(element)
            let depth = elements.count
            if depth == 1 {
                guard !sawFeed, element.isAtom("feed") else { reject(.invalidFeed, parser); return }
                sawFeed = true
            } else if depth == 2, element.isAtom("entry") {
                entryCount += 1
                guard entryCount <= 24 else { reject(.tooManyEntries, parser); return }
                entry = Entry()
            } else if depth > 16 {
                reject(.invalidFeed, parser)
            } else if entry != nil {
                if depth == 3, element.isAtom("link") {
                    readLink(attributeDict)
                } else if depth == 3, let field = Field(rawValue: elementName), element.isAtom(elementName),
                          field != .creator {
                    capture = Capture(field: field, depth: depth)
                } else if depth == 4, elements[2].isAtom("author"), element.isAtom("name") {
                    capture = Capture(field: .creator, depth: depth)
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            capture?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let text = String(data: CDATABlock, encoding: .utf8) { capture?.text += text }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            if error == nil { error = .invalidFeed }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let depth = elements.count
            guard let element = elements.popLast() else { return }
            if let capture, capture.depth == depth {
                let value = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, entry?.text[capture.field] == nil { entry?.text[capture.field] = value }
                self.capture = nil
            }
            if depth == 2, element.isAtom("entry"), let entry {
                if let book = book(from: entry), ids.insert(book.id).inserted { books.append(book) }
                self.entry = nil
            }
        }

        private func reject(_ error: ParseError, _ parser: XMLParser) {
            self.error = error
            parser.abortParsing()
        }

        private func readLink(_ attributes: [String: String]) {
            guard let href = attributes["href"] else { return }
            switch attributes["type"] {
            case "application/x-zim":
                guard attributes["rel"] == "http://opds-spec.org/acquisition/open-access",
                      let length = attributes["length"], length.utf8.allSatisfy({ (48...57).contains($0) }),
                      let bytes = Int64(length), bytes > 0,
                      let url = KiwixCatalog.metalinkURL(href), entry?.download == nil else { return }
                entry?.download = (url, bytes)
            case "text/html":
                if entry?.readerURL == nil { entry?.readerURL = KiwixCatalog.readerURL(href) }
            default: break
            }
        }

        private func book(from entry: Entry) -> Book? {
            guard let identifier = entry.text[.id], identifier.hasPrefix("urn:uuid:"),
                  let id = UUID(uuidString: String(identifier.dropFirst("urn:uuid:".count))),
                  let title = entry.text[.title], let updated = entry.text[.updated],
                  date.date(from: updated) != nil || fractionalDate.date(from: updated) != nil,
                  let download = entry.download else { return nil }
            let language = entry.text[.language] ?? ""
            let languages = language.split(separator: ",", omittingEmptySubsequences: false)
            let validLanguages = language.utf8.count <= 256 && languages.allSatisfy { code in
                code.utf8.count == 3 && code.utf8.allSatisfy { (97...122).contains($0) }
            }
            return Book(id: id, title: String(title.prefix(256)), summary: String((entry.text[.summary] ?? "").prefix(1_024)),
                        language: validLanguages ? language : "", updated: updated,
                        creator: String((entry.text[.creator] ?? "").prefix(256)), estimatedBytes: download.estimatedBytes,
                        metalinkURL: download.url, readerURL: entry.readerURL)
        }
    }

    private static func metalinkURL(_ href: String) -> URL? {
        guard let components = trustedComponents(href, hosts: ["download.kiwix.org", "lb.download.kiwix.org"]),
              let path = safePath(components.percentEncodedPath), path.count == 3, path[0] == "zim",
              path[2].hasSuffix(".zim.meta4"), path[2].count > ".zim.meta4".count else { return nil }
        return components.url
    }

    private static func readerURL(_ href: String) -> URL? {
        guard let components = trustedComponents(href, hosts: ["browse.library.kiwix.org"]),
              let path = safePath(components.percentEncodedPath), path.count == 2, path[0] == "content" else { return nil }
        return components.url
    }

    private static func trustedComponents(_ href: String, hosts: Set<String>) -> URLComponents? {
        guard href.utf8.count <= 2_048, let components = URLComponents(string: href),
              components.scheme == "https", let host = components.percentEncodedHost, hosts.contains(host),
              href.hasPrefix("https://\(host)/"), components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil else { return nil }
        return components
    }

    private static func safePath(_ path: String) -> [Substring]? {
        guard path.hasPrefix("/") else { return nil }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard segments.allSatisfy({ segment in
            !segment.isEmpty && segment != "." && segment != ".." && segment.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                    $0 == 45 || $0 == 46 || $0 == 95
            }
        }) else { return nil }
        return segments
    }
}
