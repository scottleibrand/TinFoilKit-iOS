import Foundation
import XCTest
@testable import TinfoilKit

final class RegionalBundleTransferTests: XCTestCase {
    func testFullReplyCanRestartAResumeFromByteZero() throws {
        let result = try RegionalBundleResponse(
            response(status: 200, headers: ["Content-Length": "10", "ETag": "\"new\""]),
            total: 10, limit: 10, requestedOffset: 3, requestedValidator: "\"old\""
        )
        XCTAssertEqual(result.offset, 0)
        XCTAssertEqual(result.validator, "\"new\"")
        let weak = try RegionalBundleResponse(
            response(status: 200, headers: ["Content-Length": "10", "ETag": "W/\"new\""]),
            total: 10, limit: 10, requestedOffset: 0, requestedValidator: nil
        )
        XCTAssertNil(weak.validator)
    }

    func testPartialReplyRequiresExactRemainingRangeAndStrongValidator() throws {
        let headers = ["Content-Length": "7", "Content-Range": "bytes 3-9/10", "ETag": "\"stable\""]
        let accepted = try RegionalBundleResponse(
            response(status: 206, headers: headers),
            total: 10, limit: 10, requestedOffset: 3, requestedValidator: "\"stable\""
        )
        XCTAssertEqual(accepted.offset, 3)

        for (header, invalid) in [
            ("Content-Range", "bytes 3-8/10"),
            ("Content-Range", "bytes 0-9/10"),
            ("Content-Range", "bytes 3-9/11"),
            ("ETag", "\"new\""),
            ("ETag", "W/\"stable\""),
            ("Content-Length", "8"),
            ("Content-Encoding", "gzip")
        ] {
            var rejected = headers
            rejected[header] = invalid
            XCTAssertThrowsError(try RegionalBundleResponse(
                response(status: 206, headers: rejected),
                total: 10, limit: 10, requestedOffset: 3, requestedValidator: "\"stable\""
            ), header + " " + invalid)
        }
    }

    func testManifestResponseCannotExceedItsCapOrUseAPartialResponse() throws {
        let oversized = try response(status: 200, headers: ["Content-Length": "65537"])
        XCTAssertThrowsError(try RegionalBundleResponse(
            oversized, total: nil, limit: 65_536, requestedOffset: 0, requestedValidator: nil
        )) { XCTAssertEqual($0 as? RegionalBundleDownloadError, .size) }
        let partial = try response(status: 206, headers: ["Content-Length": "3", "Content-Range": "bytes 0-2/10"])
        XCTAssertThrowsError(try RegionalBundleResponse(
            partial, total: nil, limit: 65_536, requestedOffset: 0, requestedValidator: nil
        )) { XCTAssertEqual($0 as? RegionalBundleDownloadError, .response) }
    }

    func testDownloadSourceRejectsUntrustedURLFormsAndMalformedHash() throws {
        let hash = String(repeating: "B", count: 64)
        let source = try RegionalBundleDownloadSource(url: " https://example.invalid/manifest.json ", sha256: hash)
        XCTAssertEqual(source.sha256, hash.lowercased())
        for invalid in [
            "http://example.invalid/manifest.json", "https://user@example.invalid/manifest.json",
            "https://example.invalid/manifest.json#fragment", "file:///manifest.json"
        ] {
            XCTAssertThrowsError(try RegionalBundleDownloadSource(url: invalid, sha256: hash))
        }
        XCTAssertThrowsError(try RegionalBundleDownloadSource(
            url: "https://example.invalid/manifest.json", sha256: String(hash.dropLast())
        ))
    }

    func testRedirectsKeepRangeAndRejectUnsafeDestinations() throws {
        var original = URLRequest(url: try XCTUnwrap(URL(string: "https://example.invalid/artifact")))
        original.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        original.setValue("bytes=3-", forHTTPHeaderField: "Range")
        original.setValue("\"stable\"", forHTTPHeaderField: "If-Range")
        let mirror = URLRequest(url: try XCTUnwrap(URL(string: "https://mirror.example.invalid/artifact")))
        let redirect = try XCTUnwrap(RegionalBundleResponse.redirect(mirror, preserving: original))
        XCTAssertEqual(redirect.url, mirror.url)
        XCTAssertEqual(redirect.value(forHTTPHeaderField: "Range"), "bytes=3-")
        XCTAssertEqual(redirect.value(forHTTPHeaderField: "If-Range"), "\"stable\"")
        XCTAssertEqual(redirect.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        for address in ["http://mirror.example.invalid/artifact", "https://user@mirror.example.invalid/artifact"] {
            let target = URLRequest(url: try XCTUnwrap(URL(string: address)))
            XCTAssertNil(RegionalBundleResponse.redirect(target, preserving: original))
        }
    }

    private func response(status: Int, headers: [String: String]) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.invalid/artifact")!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers
        ))
    }
}
