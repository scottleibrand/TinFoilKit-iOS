import Foundation
import XCTest
@testable import TinfoilKit

final class OnlineSourceArchiverTests: XCTestCase {
    func testExtractsArticleWithoutPageChromeOrScripts() throws {
        let snapshot = try OnlineSourceArchiver.snapshotHTML("""
            <html><body><nav>Menu</nav><article>Featured elsewhere</article>
            <main><h1>Water service update</h1><p>Reservoir inspection is complete.</p>
            <script>alert('not article text')</script><aside>Advertisement</aside></main></body></html>
            """)
        XCTAssertEqual(snapshot.text, "Water service update Reservoir inspection is complete.")
        XCTAssertNil(snapshot.note)
    }

    func testRespectsPublisherStorageControls() throws {
        let snapshot = try OnlineSourceArchiver.snapshotHTML("""
            <html><head><meta name="robots" content="index, NOARCHIVE"></head>
            <body><main>Maintenance update</main></body></html>
            """)
        XCTAssertNil(snapshot.text)
        XCTAssertNotNil(snapshot.note)

        let url = try XCTUnwrap(URL(string: "https://www.example.org/source"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Cache-Control": "public, no-store"]
        ))
        XCTAssertFalse(OnlineSourceArchiver.allowsStorage(response))
    }

    func testRejectsLocalAndNonWebCitationURLs() throws {
        for raw in ["file:///private/test", "http://127.0.0.1/index", "https://foo.local/",
                    "https://user@www.example.org/", "https://www.example.org:8080/"] {
            XCTAssertFalse(OnlineSourceArchiver.isPublicWebURL(try XCTUnwrap(URL(string: raw))), raw)
        }
        XCTAssertTrue(OnlineSourceArchiver.isPublicWebURL(try XCTUnwrap(URL(string: "https://www.example.org/source"))))
    }
}
