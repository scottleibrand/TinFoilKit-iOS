import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct KiwixMetalink: Equatable, Sendable {
    static let maximumResponseBytes = 1_048_576

    let filename: String
    let byteCount: Int64
    let sha256: String

    enum ParseError: LocalizedError {
        case responseTooLarge, invalidMetadata

        var errorDescription: String? {
            switch self {
            case .responseTooLarge: "The publisher’s archive metadata exceeded the download limit."
            case .invalidMetadata: "The publisher did not provide an exact archive size and SHA-256 checksum."
            }
        }
    }

    static func parse(_ data: Data, expectedFilename: String) throws -> Self {
        guard data.count <= maximumResponseBytes else { throw ParseError.responseTooLarge }
        guard !expectedFilename.isEmpty, !data.contains(0), var xml = String(data: data, encoding: .utf8),
              !xml.contains("<!DOCTYPE") else { throw ParseError.invalidMetadata }
        if xml.hasPrefix("\u{FEFF}") { xml.removeFirst() }
        // Keep the XML parser in the UTF-8 encoding inspected for DTDs above.
        if xml.hasPrefix("<?xml"), let next = xml.utf8.dropFirst(5).first, [9, 10, 13, 32].contains(next) {
            let utf8Declaration = #"^<\?xml\s+version\s*=\s*(?:"1\.0"|'1\.0')(?:\s+encoding\s*=\s*(?:"[Uu][Tt][Ff]-8"|'[Uu][Tt][Ff]-8'))?(?:\s+standalone\s*=\s*(?:"(?:yes|no)"|'(?:yes|no)'))?\s*\?>"#
            guard xml.range(of: utf8Declaration, options: .regularExpression) != nil else {
                throw ParseError.invalidMetadata
            }
        }
        let parser = XMLParser(data: Data(xml.utf8))
        let reader = Reader(expectedFilename: expectedFilename)
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), parser.parserError == nil, !reader.rejected, reader.sawFile,
              let byteCount = reader.byteCount, let digest = reader.sha256 else {
            throw ParseError.invalidMetadata
        }
        return Self(filename: expectedFilename, byteCount: byteCount, sha256: digest)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        private enum Field { case size, sha256 }
        private static let namespace = "urn:ietf:params:xml:ns:metalink"
        private let expectedFilename: String
        private var depth = 0
        private var insideFile = false
        private var field: Field?
        private var text = ""
        private(set) var sawFile = false
        private(set) var byteCount: Int64?
        private(set) var sha256: String?
        private(set) var rejected = false

        init(expectedFilename: String) {
            self.expectedFilename = expectedFilename
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            guard depth <= 32, field == nil else { reject(parser); return }
            if depth == 1 {
                if namespaceURI != Self.namespace || name != "metalink" { reject(parser) }
                return
            }
            guard namespaceURI == Self.namespace else { return }
            switch (depth, name) {
            case (2, "file"):
                guard !sawFile, let filename = attributes["name"],
                      filename.utf8.elementsEqual(expectedFilename.utf8) else { reject(parser); return }
                sawFile = true
                insideFile = true
            case (3, "size") where insideFile:
                guard byteCount == nil else { reject(parser); return }
                field = .size
            case (3, "hash") where insideFile && attributes["type"] == "sha-256":
                guard sha256 == nil else { reject(parser); return }
                field = .sha256
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard field != nil else { return }
            guard string.utf8.count <= 128 - text.utf8.count else { reject(parser); return }
            text.append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            guard field != nil else { return }
            guard let content = String(data: data, encoding: .utf8) else { reject(parser); return }
            self.parser(parser, foundCharacters: content)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { depth -= 1 }
            if depth == 2 { insideFile = false }
            guard depth == 3, let field else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field {
            case .size:
                guard value.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int64(value), count > 0 else {
                    reject(parser)
                    return
                }
                byteCount = count
            case .sha256:
                guard value.utf8.count == 64, value.utf8.allSatisfy({
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                }) else {
                    reject(parser)
                    return
                }
                sha256 = value.lowercased()
            }
            self.field = nil
            text = ""
        }

        private func reject(_ parser: XMLParser) {
            rejected = true
            parser.abortParsing()
        }
    }
}
