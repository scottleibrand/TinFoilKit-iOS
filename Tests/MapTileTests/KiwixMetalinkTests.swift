import Foundation
import XCTest
@testable import TinfoilKit

final class KiwixMetalinkTests: XCTestCase {
    private let filename = "wikipedia_en_climate-change_nopic_2026-10.zim"
    private let digest = "2a3f2aa5a4c6011f9f73e5b119546763fff099f2c3bb8a1787e750236f555ae5"
    private let namespace = "urn:ietf:params:xml:ns:metalink"
    private var size: String { "<size>90260982</size>" }
    private var hash: String { "<hash type=\"sha-256\">\(digest)</hash>" }

    func testReadsWholeArchivePinAndIgnoresPiecesAndMirrors() throws {
        let archive = """
        \(size)
        <hash type="sha-1">b6941ac2555fc630c85456f35e0a39e9193cf6c5</hash>
        <hash type="sha-256"> \(digest.uppercased()) </hash>
        <pieces length="4194304" type="sha-256"><hash type="sha-256">ignored</hash></pieces>
        <url>http://example.invalid/other.zim</url>
        """
        XCTAssertEqual(try parse(document(file(archive))),
                       KiwixMetalink(filename: filename, byteCount: 90_260_982, sha256: digest))
    }

    func testRecognizesNamespaceWithPrefixAndIgnoresForeignFields() throws {
        let xml = """
        <m:metalink xmlns:m="\(namespace)" xmlns:other="urn:example:other">
          <m:file name="\(filename)">
            <other:size>1</other:size><m:size>90260982</m:size>
            <other:hash type="sha-256">ignore</other:hash><m:hash type="sha-256">\(digest)</m:hash>
          </m:file>
        </m:metalink>
        """
        XCTAssertEqual(try parse(xml).sha256, digest)
        XCTAssertThrowsError(try parse(document(file(size + hash), namespace: "urn:example:other")))
    }

    func testRejectsWrongOrMultipleDirectFiles() {
        XCTAssertThrowsError(try parse(document(file(size + hash, name: "wrong.zim"))))
        XCTAssertThrowsError(try parse(document(file(size + hash) + file(size + hash, name: "other.zim"))))
        XCTAssertThrowsError(try parse(document("<extension>\(file(size + hash))</extension>")))
    }

    func testRequiresOneDirectSizeAndSHA256() {
        let invalid = [
            size,
            hash,
            size + size + hash,
            size + hash + hash,
            "<size>0</size>" + hash,
            "<size>9223372036854775808</size>" + hash,
            "<size><value>90260982</value></size>" + hash,
            size + "<hash type=\"sha-256\">\(String(repeating: "g", count: 64))</hash>",
            size + "<pieces type=\"sha-256\">\(hash)</pieces>",
            size + "<hash type=\"sha-1\">\(digest)</hash>"
        ]
        for content in invalid {
            XCTAssertThrowsError(try parse(document(file(content))), content)
        }
    }

    func testRejectsDTDNonUTF8MalformedAndOversizedDocuments() throws {
        let body = "<metalink xmlns=\"\(namespace)\">\(file(size + hash))</metalink>"
        XCTAssertThrowsError(try parse("<!DOCTYPE metalink>" + body))
        XCTAssertThrowsError(try parse("<!DOCTYPE metalink SYSTEM \"file:///tmp/unused\">" + body))
        XCTAssertThrowsError(try parse("<?xml\nversion=\"1.0\" encoding=\"UTF-7\"?>" + body))
        XCTAssertThrowsError(try parse(body + "<trailing/>"))
        let utf16 = try XCTUnwrap(body.data(using: .utf16LittleEndian))
        XCTAssertThrowsError(try KiwixMetalink.parse(utf16, expectedFilename: filename))
        let oversized = Data(repeating: 32, count: KiwixMetalink.maximumResponseBytes + 1)
        XCTAssertThrowsError(try KiwixMetalink.parse(oversized, expectedFilename: filename))
    }

    private func parse(_ xml: String) throws -> KiwixMetalink {
        try KiwixMetalink.parse(Data(xml.utf8), expectedFilename: filename)
    }

    private func document(_ contents: String, namespace: String? = nil) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><metalink xmlns=\"\(namespace ?? self.namespace)\">\(contents)</metalink>"
    }

    private func file(_ contents: String, name: String? = nil) -> String {
        "<file name=\"\(name ?? filename)\">\(contents)</file>"
    }
}
