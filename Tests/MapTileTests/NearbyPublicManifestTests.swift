import XCTest
@testable import TinfoilKit

final class NearbyPublicManifestTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testRejectsMalformedMetadata() {
        for id in ["", "../worksheet", "notes.txt", "private file", String(repeating: "a", count: 65)] {
            XCTAssertNil(NearbyPublicManifest(id: id, byteCount: 2, sha256: digest))
        }
        XCTAssertNil(NearbyPublicManifest(id: "worksheet", byteCount: 0, sha256: digest))
        XCTAssertNil(NearbyPublicManifest(id: "worksheet", byteCount: 2, sha256: String(digest.dropLast())))
        XCTAssertNil(NearbyPublicManifest(id: "worksheet", byteCount: 2, sha256: digest.uppercased()))
    }

    func testRejectsOffersThatDifferFromTheTrustedPin() throws {
        let known = try XCTUnwrap(NearbyPublicManifest(id: "worksheet", byteCount: 2, sha256: digest))
        for offer in [
            NearbyPublicManifest(id: "household-notes", byteCount: 2, sha256: digest),
            NearbyPublicManifest(id: "worksheet", byteCount: 3, sha256: digest),
            NearbyPublicManifest(id: "worksheet", byteCount: 2, sha256: String(repeating: "b", count: 64))
        ] {
            XCTAssertEqual(known.admit(try XCTUnwrap(offer), verifiedDigests: [], availableBytes: .max), .unlisted)
        }
    }

    func testDeduplicatesAndKeepsStagingSpace() throws {
        let known = try XCTUnwrap(NearbyPublicManifest(id: "worksheet", byteCount: 2, sha256: digest))
        XCTAssertEqual(known.admit(known, verifiedDigests: [digest], availableBytes: nil), .alreadyInstalled)
        for capacity in [nil, -1, 0, 1_048_579] as [Int64?] {
            XCTAssertEqual(known.admit(known, verifiedDigests: [], availableBytes: capacity), .insufficientStorage)
        }
        XCTAssertEqual(known.admit(known, verifiedDigests: [], availableBytes: 1_048_580), .receive)
        let oversized = try XCTUnwrap(NearbyPublicManifest(id: "worksheet", byteCount: .max, sha256: digest))
        XCTAssertEqual(oversized.admit(oversized, verifiedDigests: [], availableBytes: .max), .insufficientStorage)
    }
}
