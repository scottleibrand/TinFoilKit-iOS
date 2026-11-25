import Foundation
import XCTest
@testable import TinfoilKit

final class ArchiveWebAddressTests: XCTestCase {
    func testPreservesDirectoryKeysAndRelativeNavigation() throws {
        let home = try XCTUnwrap(ArchiveWebAddress.url(for: "www.ready.gov/", fragment: "intro"))
        XCTAssertEqual(ArchiveWebAddress.path(in: home), "www.ready.gov/")
        XCTAssertEqual(home.fragment, "intro")
        let article = try XCTUnwrap(URL(string: "power-outages#during", relativeTo: home)?.absoluteURL)
        XCTAssertEqual(ArchiveWebAddress.path(in: article), "www.ready.gov/power-outages")
        XCTAssertEqual(article.fragment, "during")
        let localPDF = try XCTUnwrap(URL(string: "sites/default/files/2024-08/ready.gov_power-outage_info-sheet.pdf",
                                         relativeTo: home)?.absoluteURL)
        XCTAssertEqual(ArchiveWebAddress.path(in: localPDF),
                       "www.ready.gov/sites/default/files/2024-08/ready.gov_power-outage_info-sheet.pdf")
    }

    func testDoesNotDoubleDecodeOrAcceptExternalURLs() throws {
        let key = "files/Notes 100% #2?.html"
        let local = try XCTUnwrap(ArchiveWebAddress.url(for: key))
        XCTAssertEqual(ArchiveWebAddress.path(in: local), key)
        let literalEscape = "files/site%2Fpath/"
        let escaped = try XCTUnwrap(ArchiveWebAddress.url(for: literalEscape))
        XCTAssertEqual(ArchiveWebAddress.path(in: escaped), literalEscape)
        for value in ["https://archive/www.ready.gov/", "zim://elsewhere/file"] {
            XCTAssertNil(ArchiveWebAddress.path(in: try XCTUnwrap(URL(string: value))))
        }
    }
}
