import XCTest
@testable import TinfoilKit

final class PackDownloadNetworkTests: XCTestCase {
    func testInterruptedDownloadsRetryWithABoundedBackoff() throws {
        let lost = URLError(.networkConnectionLost) as NSError
        let old = try XCTUnwrap(PackDownloadAttempt(description: "water-2026-09"))
        XCTAssertEqual(old.retryCount, 0)
        XCTAssertEqual(old.retryDelay(for: lost), 2)
        let retry = PackDownloadAttempt(key: old.key, retryCount: 1)
        let restored = try XCTUnwrap(PackDownloadAttempt(description: retry.taskDescription))
        XCTAssertEqual(restored.key, old.key)
        XCTAssertEqual(restored.retryDelay(for: URLError(.timedOut) as NSError), 5)
        XCTAssertEqual(PackDownloadAttempt(key: old.key, retryCount: 2).retryDelay(for: lost), 15)
        XCTAssertNil(PackDownloadAttempt(key: old.key, retryCount: 3).retryDelay(for: lost))
        XCTAssertNil(old.retryDelay(for: URLError(.cancelled) as NSError))
        XCTAssertNil(old.retryDelay(for: URLError(.serverCertificateUntrusted) as NSError))
        XCTAssertNil(PackDownloadAttempt(description: "water-2026-09|400"))
    }

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
