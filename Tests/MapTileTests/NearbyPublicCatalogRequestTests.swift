import Foundation
import XCTest
@testable import TinfoilKit

final class NearbyPublicCatalogRequestTests: XCTestCase {
    func testCatalogFrameSelectsTheExactPinnedEditionAndOffset() throws {
        let worksheet = try XCTUnwrap(NearbyPublicManifest(id: "worksheet-v1", byteCount: 32, sha256: String(repeating: "a", count: 64)))
        let log = try XCTUnwrap(NearbyPublicManifest(id: "status-log-v1", byteCount: 128, sha256: String(repeating: "b", count: 64)))
        let catalog = [worksheet, log]
        let request = NearbyPublicCatalogRequest.request(for: log, offset: 48)
        XCTAssertEqual(request.count, NearbyPublicCatalogRequest.byteCount)
        let match = try XCTUnwrap(NearbyPublicCatalogRequest.match(request, in: catalog))
        XCTAssertEqual(match.id, log.id)
        XCTAssertEqual(match.offset, 48)
        XCTAssertNil(NearbyPublicCatalogRequest.match(request, in: [worksheet]))
        XCTAssertNil(NearbyPublicCatalogRequest.match(Data(request.dropLast()), in: catalog))
        let end = NearbyPublicCatalogRequest.request(for: log, offset: log.byteCount)
        XCTAssertNil(NearbyPublicCatalogRequest.match(end, in: catalog))
        let legacy = NearbyPublicResume.request(pin: "\(worksheet.id)-\(worksheet.sha256)", offset: 0)
        XCTAssertNil(NearbyPublicCatalogRequest.match(legacy, in: catalog))
    }
}
