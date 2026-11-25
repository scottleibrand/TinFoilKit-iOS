import Foundation
import XCTest
@testable import TinfoilKit

final class KiwixCatalogTests: XCTestCase {
    private let id = "7892c766-2cd3-4b41-a48f-3fb7452777c8"
    private let metalink = "https://lb.download.kiwix.org/zim/other/fixture_en_2026-01.zim.meta4"
    private let reader = "https://browse.library.kiwix.org/content/fixture_en_2026-01"

    func testReadsAtomCatalogMetadataInFeedOrder() throws {
        let page = feed(entry(title: "Zeta &amp; others") + entry(
            identifier: "e0e3f02a-0ed9-4ff7-b4f5-bd3c806e03e6",
            title: "Alpha",
            source: "https://download.kiwix.org/zim/other/another_en_2026-01.zim.meta4"
        ))
        let books = try KiwixCatalog.parse(page)
        XCTAssertEqual(books.map(\.title), ["Zeta & others", "Alpha"])
        let book = try XCTUnwrap(books.first)
        XCTAssertEqual(book.id, try XCTUnwrap(UUID(uuidString: id)))
        XCTAssertEqual(book.summary, "Reference material & examples")
        XCTAssertEqual(book.language, "eng,spa")
        XCTAssertEqual(book.updated, "2026-01-27T00:00:00Z")
        XCTAssertEqual(book.creator, "Example & Contributors")
        XCTAssertEqual(book.estimatedBytes, 20_925_440)
        XCTAssertEqual(book.metalinkURL.absoluteString, metalink)
        XCTAssertEqual(book.archiveURL.absoluteString, String(metalink.dropLast(".meta4".count)))
        XCTAssertEqual(book.readerURL?.absoluteString, reader)
    }

    func testRejectsForgedOrNoncanonicalAcquisitionLinks() throws {
        for source in [
            "https://lb.download.kiwix.org.example.invalid/zim/other/fixture.zim.meta4",
            "https://lb.download.kiwix.org@example.invalid/zim/other/fixture.zim.meta4",
            "https://example.invalid@download.kiwix.org/zim/other/fixture.zim.meta4",
            "http://lb.download.kiwix.org/zim/other/fixture.zim.meta4",
            "https://lb.download.kiwix.org:8443/zim/other/fixture.zim.meta4",
            "https://lb.download.kiwix.org/zim/other/../fixture.zim.meta4",
            "https://lb.download.kiwix.org/zim/other/%2E%2E.zim.meta4",
            "https://lb.download.kiwix.org/zim/other/fixture.zim.meta4?%FF",
            "https://lb.download.kiwix.org/zim/other/fixture.zim.meta4#fragment",
            "https://lb.download.kiwix.org/zim/other/fixture.zim",
            "/zim/other/fixture.zim.meta4"
        ] {
            XCTAssertTrue(try KiwixCatalog.parse(feed(entry(source: source))).isEmpty, source)
        }
        XCTAssertTrue(try KiwixCatalog.parse(feed(entry(relation: "alternate"))).isEmpty)
        XCTAssertTrue(try KiwixCatalog.parse(feed(entry(length: "0"))).isEmpty)
    }

    func testUntrustedReaderLinkAndDuplicateIdentifierAreIgnored() throws {
        for invalidReader in [
            "https://browse.library.kiwix.org/content/../untrusted",
            "https://browse.library.kiwix.org.example.invalid/content/fixture",
            "https://browse.library.kiwix.org/content/fixture?query=example"
        ] {
            let books = try KiwixCatalog.parse(feed(entry(reader: invalidReader) + entry(title: "Duplicate")))
            XCTAssertEqual(books.map(\.title), ["Fixture reference"])
            XCTAssertNil(books.first?.readerURL)
        }
    }

    func testRejectsNonAtomRootAndEntityDeclarations() throws {
        let wrongNamespace = Data("<feed xmlns=\"https://example.invalid\"/>".utf8)
        XCTAssertThrowsError(try KiwixCatalog.parse(wrongNamespace))
        let brokenXML = Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><entry></feed>".utf8)
        XCTAssertThrowsError(try KiwixCatalog.parse(brokenXML))
        let entity = Data("""
            <!DOCTYPE feed [<!ENTITY external SYSTEM "https://example.invalid/remote.dtd">]>
            <feed xmlns="http://www.w3.org/2005/Atom">&external;</feed>
            """.utf8)
        XCTAssertThrowsError(try KiwixCatalog.parse(entity))
    }

    func testRejectsOversizedOrOverfullCatalogPage() throws {
        XCTAssertThrowsError(try KiwixCatalog.parse(Data(repeating: 32, count: 512 * 1_024 + 1)))
        XCTAssertThrowsError(try KiwixCatalog.parse(feed(String(repeating: entry(), count: 25))))
    }

    func testAllowsUTF8DeclarationAndRejectsAlternateDeclaredEncoding() throws {
        let atom = String(decoding: feed(entry()), as: UTF8.self)
        let valid = Data(("\u{FEFF}<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + atom).utf8)
        XCTAssertEqual(try KiwixCatalog.parse(valid).count, 1)
        let alternate = Data(("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>" + atom).utf8)
        XCTAssertThrowsError(try KiwixCatalog.parse(alternate))
    }

    private func feed(_ content: String) -> Data {
        Data("<feed xmlns=\"http://www.w3.org/2005/Atom\">\(content)</feed>".utf8)
    }

    private func entry(identifier: String? = nil, title: String = "Fixture reference", source: String? = nil,
                       reader: String? = nil, relation: String = "http://opds-spec.org/acquisition/open-access",
                       length: String = "20925440") -> String {
        """
        <entry>
            <id>urn:uuid:\(identifier ?? id)</id>
            <title>\(title)</title>
            <updated>2026-01-27T00:00:00Z</updated>
            <summary><![CDATA[Reference material & examples]]></summary>
            <language>eng,spa</language>
            <author><name>Example &amp; Contributors</name></author>
            <publisher><name>Example Publisher</name></publisher>
            <link type="text/html" href="\(reader ?? self.reader)"/>
            <link type="application/x-zim" rel="\(relation)" href="\(source ?? metalink)" length="\(length)"/>
        </entry>
        """
    }
}
