import XCTest
@testable import TinfoilKit

final class PackDownloadNetworkTests: XCTestCase {
    func testChecksumRetryKeepsSavedNetworkAndStopsAfterOneFreshTransfer() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = "pack-2026-10"
        let host = "mirror.example.org"
        let temporary = directory.appendingPathComponent("download.tmp")
        let transfer = PackTransfer(directory: directory) { _ in }
        let first = PackDownloadAttempt(key: key, retryCount: 2, usesMirror: true)
        let firstContext = PackTransfer.VerificationContext(attempt: first, network: .cellularAllowed, host: host)
        try Data([0]).write(to: temporary)
        try transfer.stageDownload(at: temporary, key: key, verification: firstContext)

        let relaunched = PackTransfer(directory: directory) { _ in }
        let restored = try XCTUnwrap(relaunched.verificationContext(key))
        XCTAssertEqual(restored.network, .cellularAllowed)
        XCTAssertEqual(restored.host, host)
        XCTAssertNil(restored.attempt(for: "other-pack"))
        let checksumRetry = try XCTUnwrap(restored.attempt(for: key)?.checksumRetry)
        XCTAssertEqual(checksumRetry.retryCount, 0)
        let attempt = try XCTUnwrap(PackDownloadAttempt(description: checksumRetry.transportRetry.taskDescription))
        XCTAssertTrue(attempt.usesMirror)
        XCTAssertNil(attempt.checksumRetry)

        relaunched.discardDownload(key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transfer.downloadURL(key).path))
        XCTAssertNil(relaunched.verificationContext(key))
        try Data([1]).write(to: temporary)
        let secondContext = PackTransfer.VerificationContext(attempt: attempt, network: restored.network, host: host)
        try relaunched.stageDownload(at: temporary, key: key, verification: secondContext)
        let afterRetry = try XCTUnwrap(transfer.verificationContext(key))
        XCTAssertNil(afterRetry.attempt(for: key)?.checksumRetry)
        XCTAssertTrue(try XCTUnwrap(afterRetry.failureMessage).contains(host))
        XCTAssertEqual(try Data(contentsOf: transfer.downloadURL(key)), Data([1]))
    }

    func testMirrorAttemptsAndResumeDataStaySeparateBySourceAndNetwork() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = PackTransfer(directory: directory) { _ in }
        let key = "pack-2026-10"
        let primary = PackDownloadAttempt(key: key)
        let scheduled = try XCTUnwrap(PackDownloadAttempt(description: primary.mirror.transportRetry.taskDescription))
        XCTAssertEqual(scheduled.key, key)
        XCTAssertEqual(scheduled.retryCount, 1)
        XCTAssertTrue(scheduled.usesMirror)
        XCTAssertNil(primary.checksumRetry?.mirror.checksumRetry)
        XCTAssertFalse(try XCTUnwrap(PackDownloadAttempt(description: "\(key)|1")).usesMirror)

        let primaryBytes = Data([1, 2])
        let mirrorBytes = Data([3, 4])
        try transfer.saveResume(primaryBytes, key: key, network: .cellularAllowed)
        try transfer.saveResume(mirrorBytes, key: key, network: .cellularAllowed, usesMirror: true)
        XCTAssertEqual(try Data(contentsOf: transfer.resumeURL(key, network: .cellularAllowed)), primaryBytes)
        XCTAssertEqual(try Data(contentsOf: transfer.resumeURL(key, network: .cellularAllowed, usesMirror: true)), mirrorBytes)
        XCTAssertTrue(transfer.hasMirrorResume(key, network: .cellularAllowed))
        XCTAssertFalse(transfer.hasMirrorResume(key, network: .wifiOnly))
        XCTAssertEqual(transfer.resumeNetwork(key), .cellularAllowed)
        transfer.clearResume(key)
        XCTAssertFalse(transfer.hasResume(key))
    }

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

    func testManualResumePreservesCheckpointNetwork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = PackTransfer(directory: directory) { _ in }
        let key = "water-2026-09"
        let checkpoint = Data([1, 2, 3])
        XCTAssertEqual(transfer.resumeNetwork(key), .wifiOnly)
        try transfer.saveResume(checkpoint, key: key, network: .cellularAllowed)
        XCTAssertEqual(transfer.resumeNetwork(key), .cellularAllowed)
        XCTAssertEqual(try Data(contentsOf: transfer.resumeURL(key, network: .cellularAllowed)), checkpoint)
        try transfer.saveResume(checkpoint, key: key, network: .wifiOnly)
        XCTAssertEqual(transfer.resumeNetwork(key), .wifiOnly)
        transfer.clearResume(key)
        XCTAssertFalse(transfer.hasResume(key))
    }

    func testTemporaryPublisherErrorsBackOffAndPermanentErrorsStop() throws {
        let url = try XCTUnwrap(URL(string: "https://example.org/pack.zim"))
        func response(_ status: Int, retryAfter: String? = nil) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                         headerFields: retryAfter.map { ["Retry-After": $0] }))
        }
        let first = PackDownloadAttempt(key: "pack")
        XCTAssertEqual(first.retryDelay(for: try response(503)), 2)
        XCTAssertEqual(first.retryDelay(for: try response(429, retryAfter: "30")), 30)
        XCTAssertNil(first.retryDelay(for: try response(503, retryAfter: "86400")))
        XCTAssertNil(first.retryDelay(for: try response(404)))
        XCTAssertNil(PackDownloadAttempt(key: "pack", retryCount: 3).retryDelay(for: try response(503)))
        XCTAssertTrue(first.canTryMirror(for: try response(404)))
        XCTAssertFalse(first.mirror.canTryMirror(for: try response(404)))
        XCTAssertFalse(first.canTryMirror(for: try response(429)))
        XCTAssertFalse(first.canTryMirror(for: URLError(.serverCertificateUntrusted) as NSError))
        XCTAssertFalse(first.canTryMirror(for: URLError(.notConnectedToInternet) as NSError))
    }

    func testFallbackMirrorIsPinnedToOneEdition() throws {
        let catalog = try XCTUnwrap(Bundle.main.url(forResource: "PackCatalog", withExtension: "json"))
        let entries = try PackCatalog.load(from: catalog)
        let mirrored = try XCTUnwrap(entries.first { $0.pack.id == "wikipedia-es-top-mini" && $0.isDefault })
        XCTAssertEqual(mirrored.pack.version, "2026-10")
        XCTAssertEqual(mirrored.pack.source.host, "ftp.fau.de")
        XCTAssertEqual(mirrored.fallbackMirror?.host, "dumps.wikimedia.org")
        XCTAssertEqual(mirrored.fallbackMirror?.lastPathComponent, mirrored.pack.source.lastPathComponent)
        XCTAssertTrue(entries.filter { $0.pack.id == mirrored.pack.id && $0.id != mirrored.id }
            .allSatisfy { $0.fallbackMirror == nil })
    }
}
