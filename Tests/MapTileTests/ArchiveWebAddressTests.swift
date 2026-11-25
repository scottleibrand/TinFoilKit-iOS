import Foundation
import XCTest
@testable import TinfoilKit

final class ArchiveWebAddressTests: XCTestCase {
    func testPreservesReadyGovDirectoryAndSlashlessChild() throws {
        let home = try XCTUnwrap(ArchiveWebAddress.url(for: "www.ready.gov/"))
        XCTAssertEqual(ArchiveWebAddress.path(in: home), "www.ready.gov/")
        XCTAssertEqual(ArchiveWebAddress.candidates(in: home), ["www.ready.gov/"])
        let article = try XCTUnwrap(URL(string: "power-outages", relativeTo: home))
        XCTAssertEqual(ArchiveWebAddress.path(in: article), "www.ready.gov/power-outages")
        XCTAssertEqual(ArchiveWebAddress.candidates(in: article), ["www.ready.gov/power-outages"])
        let anchor = try XCTUnwrap(URL(string: "#main-content", relativeTo: home)?.absoluteURL)
        XCTAssertEqual(ArchiveWebAddress.candidates(in: anchor), ["www.ready.gov/"])
        XCTAssertEqual(anchor.fragment, "main-content")
        let pdfPath = "sites/default/files/2024-08/ready.gov_power-outage_info-sheet.pdf"
        let localPDF = try XCTUnwrap(URL(string: pdfPath, relativeTo: home))
        XCTAssertEqual(ArchiveWebAddress.candidates(in: localPDF), ["www.ready.gov/" + pdfPath])
    }

    func testPrefersExactQueryAndKeepsBookmarkKey() throws {
        let plainKey = "www.ready.gov/collection/2025-npm-graphics"
        let fullKey = plainKey + "?page=1"
        let page = try XCTUnwrap(ArchiveWebAddress.url(for: plainKey))
        let request = try XCTUnwrap(URL(string: "?page=1#resources", relativeTo: page))
        XCTAssertEqual(ArchiveWebAddress.candidates(in: request), [fullKey, plainKey])
        XCTAssertEqual(ArchiveWebAddress.path(in: request), plainKey)

        let bookmark = try XCTUnwrap(ArchiveWebAddress.canonicalURL(for: fullKey, relativeTo: request))
        XCTAssertEqual(ArchiveWebAddress.path(in: bookmark), fullKey)
        XCTAssertEqual(ArchiveWebAddress.candidates(in: bookmark), [fullKey])
        XCTAssertEqual(bookmark.fragment, "resources")
        XCTAssertNil(URLComponents(url: bookmark, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
    }

    func testEscapedQueryAndFragmentHaveSeparateRoles() throws {
        let request = try XCTUnwrap(URL(string: "zim://archive/files/Look%20up?q=a%2fb+%2B%3F%23#part%20two%3F%23"))
        let key = "files/Look up?q=a%2fb+%2B%3F%23"
        XCTAssertEqual(ArchiveWebAddress.candidates(in: request), [key, "files/Look up"])
        let canonical = try XCTUnwrap(ArchiveWebAddress.canonicalURL(for: key, relativeTo: request))
        XCTAssertEqual(ArchiveWebAddress.candidates(in: canonical), [key])
        XCTAssertEqual(URLComponents(url: canonical, resolvingAgainstBaseURL: false)?.fragment, "part two?#")

        let queryOnly = try XCTUnwrap(URL(string: "zim://archive/files/page?"))
        XCTAssertEqual(ArchiveWebAddress.candidates(in: queryOnly), ["files/page?", "files/page"])
    }

    func testCanonicalRedirectTargetResolvesRelativeLinksInItsDirectory() throws {
        let source = try XCTUnwrap(URL(string: "zim://archive/www.fema.gov/cert#main-content"))
        let directory = "www.fema.gov/emergency-managers/individuals-communities/preparedness-activities-webinars"
        let destination = directory + "/community-emergency-response-team"
        let canonical = try XCTUnwrap(ArchiveWebAddress.canonicalURL(for: destination, relativeTo: source))
        let child = try XCTUnwrap(URL(string: "overview", relativeTo: canonical))
        XCTAssertEqual(ArchiveWebAddress.path(in: canonical), destination)
        XCTAssertEqual(canonical.fragment, "main-content")
        XCTAssertEqual(ArchiveWebAddress.path(in: child), directory + "/overview")
    }

    func testDoesNotDoubleDecodeLiteralEscapes() throws {
        let key = "files/Notes 100% #2?.html"
        let local = try XCTUnwrap(ArchiveWebAddress.url(for: key))
        XCTAssertEqual(ArchiveWebAddress.path(in: local), key)
        XCTAssertEqual(ArchiveWebAddress.candidates(in: local), [key])

        let literalEscape = "files/site%2Fpath/"
        let escaped = try XCTUnwrap(ArchiveWebAddress.url(for: literalEscape))
        XCTAssertEqual(ArchiveWebAddress.path(in: escaped), literalEscape)
        XCTAssertEqual(ArchiveWebAddress.candidates(in: escaped), [literalEscape])
    }

    func testRejectsExternalAndNoncanonicalAuthorities() throws {
        for value in [
            "https://archive/www.ready.gov/", "zim://elsewhere/file", "zim://archive.example/file",
            "zim://archive:443/file", "zim://user@archive/file", "zim://user:secret@archive/file"
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertNil(ArchiveWebAddress.path(in: url))
            XCTAssertTrue(ArchiveWebAddress.candidates(in: url).isEmpty)
            XCTAssertNil(ArchiveWebAddress.canonicalURL(for: "file", relativeTo: url))
        }
    }
}
