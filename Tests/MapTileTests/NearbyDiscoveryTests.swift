import XCTest
@testable import TinfoilKit

final class NearbyDiscoveryTests: XCTestCase {
    private let id = "1f4b6d8a0e2c4a6b8d0f2e4c6a8b0d2f"

    func testRecognizesOnlyCurrentRandomIdentifiersOnLocalService() {
        let name = "tfk-v1-\(id)"
        XCTAssertEqual(NearbyDiscovery.peerID(from: name, type: "_tfk-nearby._tcp", domain: "local."), id)
        XCTAssertNil(NearbyDiscovery.peerID(from: name, type: "_tfk-nearby._tcp", domain: "example.org."))
        XCTAssertNil(NearbyDiscovery.peerID(from: name, type: "_http._tcp", domain: "local."))
        XCTAssertNil(NearbyDiscovery.peerID(from: name, type: "_tfk-nearby._tcp", domain: "local.", excluding: id))
    }

    func testRejectsPersonalNamesAndOtherWireVersions() {
        for invalid in ["My iPhone", "tfk-v1-\(id)-device", "tfk-v1-\(id.uppercased())",
                        "tfk-v2-\(id)", "tfk-v1-1234"] {
            XCTAssertNil(NearbyDiscovery.peerID(from: invalid, type: "_tfk-nearby._tcp", domain: "local."))
        }
    }
}
