import Foundation
import XCTest
@testable import TinfoilKit

final class PMTileRangeReadTests: XCTestCase {
    func testReadsOnlyTheHeaderDirectoryAndTileRanges() async throws {
        let data = try await archive(path: "valid").vectorTile(.init(zoom: 0, x: 0, y: 0))
        XCTAssertEqual(data, Data([42]))
    }

    func testRejectsAnArchiveWhoseLengthChangesBetweenRanges() async throws {
        do {
            _ = try await archive(path: "changed").vectorTile(.init(zoom: 0, x: 0, y: 0))
            XCTFail("Expected an archive change.")
        } catch PMTileArchive.ArchiveError.changed {
        }
    }

    private func archive(path: String) -> PMTileArchive {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeProtocol.self]
        return PMTileArchive(url: URL(string: "https://example.invalid/\(path)")!,
                             session: URLSession(configuration: configuration))
    }

    private final class RangeProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  request.value(forHTTPHeaderField: "Accept-Encoding") == "identity" else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let body: Data
            let range: String
            let conditional = request.value(forHTTPHeaderField: "If-Match")
            switch request.value(forHTTPHeaderField: "Range") {
            case "bytes=0-126" where conditional == nil:
                var header = Data(repeating: 0, count: 127)
                header.replaceSubrange(0..<8, with: Data("PMTiles".utf8) + Data([3]))
                header[8] = 127
                header[16] = 5
                header[56] = 132
                header[64] = 1
                header[97] = 1
                header[98] = 1
                header[99] = 1
                body = header
                range = "bytes 0-126/133"
            case "bytes=127-131" where conditional == "\"synthetic\"":
                body = Data([1, 0, 1, 1, 1])
                range = url.lastPathComponent == "changed" ? "bytes 127-131/134" : "bytes 127-131/133"
            case "bytes=132-132" where conditional == "\"synthetic\"":
                body = Data([42])
                range = "bytes 132-132/133"
            default:
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Range": range, "ETag": "\"synthetic\""])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}
