import XCTest
@testable import TinfoilKit

final class PackDownloadNetworkTests: XCTestCase {
    func testBackgroundPoliciesKeepTheExistingSessionAndSeparateResumeData() {
        let wifi = PackDownloadNetwork.wifiOnly.configuration()
        let cellular = PackDownloadNetwork.cellularAllowed.configuration()
        XCTAssertEqual(wifi.identifier, "org.tinfoilkit.ios.publisher-packs")
        XCTAssertNotEqual(wifi.identifier, cellular.identifier)
        XCTAssertFalse(wifi.allowsCellularAccess)
        XCTAssertTrue(cellular.allowsCellularAccess)
        XCTAssertTrue(wifi.sessionSendsLaunchEvents)
        XCTAssertTrue(cellular.sessionSendsLaunchEvents)
        XCTAssertEqual(PackDownloadNetwork.wifiOnly.resumeExtension, "resume")
        XCTAssertNotEqual(PackDownloadNetwork.wifiOnly.resumeExtension, PackDownloadNetwork.cellularAllowed.resumeExtension)
    }
}
