import Foundation
import XCTest
@testable import TinfoilKit

final class NearbyPublicReferenceTests: XCTestCase {
    func testCatalogDefaultsKeepTheLegacyWorksheetPin() {
        let legacy = NearbyPublicReference(bundledFile: nil)
        XCTAssertEqual(legacy.entry, NearbyPublicReference.worksheet)
        XCTAssertEqual(legacy.entry.id, NearbyPublicReference.id)
        XCTAssertEqual(legacy.entry.manifest.byteCount, NearbyPublicReference.expectedByteCount)
        XCTAssertEqual(legacy.resumePin, NearbyPublicReference.resumePin)
        XCTAssertEqual(NearbyPublicReference.mainCatalog.map(\.id),
                       ["household-check-in-v1", "neighborhood-status-log-v1"])
        XCTAssertEqual(NearbyPublicReference.catalogReferences.map(\.entry), NearbyPublicReference.mainCatalog)
    }

    func testCatalogItemsInstallAndResumeIndependently() throws {
        let directory = self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstBytes = Data("fixture-doc-one".utf8)
        let secondBytes = Data("fixture-doc-two".utf8)
        let first = try fixtureReference(
            id: "first-reference-v1", bytes: firstBytes,
            digest: "143fa5e83179d994f50995cc23fc74f665f3572acf90f0a214e368a05c6c8fa5", directory: directory
        )
        let second = try fixtureReference(
            id: "second-reference-v1", bytes: secondBytes,
            digest: "a356698b153c54b1e6b1167cee624e2dc101fcef1183560dd65e4e7c69e150e4", directory: directory
        )
        let firstPrefix = Data(firstBytes.prefix(5))
        let secondPrefix = Data(secondBytes.prefix(12))
        try first.saveCheckpoint(firstPrefix)
        try second.saveCheckpoint(secondPrefix)

        XCTAssertEqual(first.checkpoint(), firstPrefix)
        XCTAssertEqual(second.checkpoint(), secondPrefix)
        XCTAssertThrowsError(try first.receiveVerified(secondBytes)) {
            XCTAssertEqual($0 as? NearbyPublicReference.StoreError, .invalidReference)
        }
        XCTAssertTrue(try first.receiveVerified(firstBytes))
        first.removeCheckpoint()
        XCTAssertEqual(first.admission(), .alreadyInstalled)
        XCTAssertEqual(second.admission(), .receive)
        XCTAssertTrue(first.checkpoint().isEmpty)
        XCTAssertEqual(second.checkpoint(), secondPrefix)
        XCTAssertNil(second.loadVerified())
        XCTAssertTrue(try second.receiveVerified(secondBytes))

        let reopenedFirst = NearbyPublicReference(entry: first.entry, directory: directory, bundledFile: nil)
        let reopenedSecond = NearbyPublicReference(entry: second.entry, directory: directory, bundledFile: nil)
        XCTAssertEqual(reopenedFirst.loadVerified(), firstBytes)
        XCTAssertEqual(reopenedSecond.loadVerified(), secondBytes)
        XCTAssertFalse(try reopenedSecond.receiveVerified(secondBytes))
    }

    func testPriorDigestCheckpointCannotContinueChangedEdition() throws {
        let directory = self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "reference-v1"
        let first = try fixtureReference(
            id: id, bytes: Data("fixture-doc-one".utf8),
            digest: "143fa5e83179d994f50995cc23fc74f665f3572acf90f0a214e368a05c6c8fa5", directory: directory
        )
        let replacement = try fixtureReference(
            id: id, bytes: Data("fixture-doc-two".utf8),
            digest: "a356698b153c54b1e6b1167cee624e2dc101fcef1183560dd65e4e7c69e150e4", directory: directory
        )
        let prefix = Data("fixture-doc-on".utf8)
        try first.saveCheckpoint(prefix)
        XCTAssertNotEqual(first.resumePin, replacement.resumePin)
        XCTAssertEqual(first.checkpoint(), prefix)
        XCTAssertTrue(replacement.checkpoint().isEmpty)
        XCTAssertEqual(replacement.admission(), .receive)
    }

    func testRejectsUnlistedBytesBeforeWriting() throws {
        let directory = self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NearbyPublicReference(directory: directory, bundledFile: nil, availableCapacity: { _ in .max })

        XCTAssertThrowsError(try store.receiveVerified(Data("hello".utf8)))
        XCTAssertThrowsError(try store.receiveVerified(Data(repeating: 0, count: NearbyPublicReference.expectedByteCount)))
        XCTAssertNil(store.loadVerified())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testVerifiedReferenceCanBeReceivedAndReopened() throws {
        let asset = try bundledReference()
        let sender = NearbyPublicReference(directory: self.directory(), bundledFile: asset)
        let bytes = try XCTUnwrap(sender.loadVerified())
        let directory = self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recipient = NearbyPublicReference(directory: directory, bundledFile: nil, availableCapacity: { _ in .max })

        XCTAssertNil(recipient.loadVerified())
        XCTAssertEqual(recipient.admission(), .receive)
        XCTAssertTrue(try recipient.receiveVerified(bytes))
        XCTAssertFalse(try recipient.receiveVerified(bytes))
        XCTAssertEqual(recipient.admission(), .alreadyInstalled)
        XCTAssertEqual(
            NearbyPublicReference(directory: directory, bundledFile: nil).loadVerified(),
            bytes
        )
        XCTAssertThrowsError(try recipient.receiveVerified(Data("changed".utf8)))
        XCTAssertEqual(recipient.loadVerified(), bytes)
    }

    func testRecipientDeclinesWhenCapacityIsInsufficient() throws {
        let data = try Data(contentsOf: bundledReference())
        let directory = self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NearbyPublicReference(directory: directory, bundledFile: nil, availableCapacity: { _ in 0 })

        XCTAssertEqual(store.admission(), .insufficientStorage)
        XCTAssertThrowsError(try store.receiveVerified(data)) { error in
            XCTAssertEqual(error as? NearbyPublicReference.StoreError, .insufficientStorage)
        }
        XCTAssertNil(store.loadVerified())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func bundledReference() throws -> URL {
        guard let asset = Bundle.main.url(forResource: NearbyPublicReference.id, withExtension: "txt") else {
            throw XCTSkip("This profile receives the public reference from another device.")
        }
        return asset
    }

    private func fixtureReference(id: String, bytes: Data, digest: String, directory: URL) throws -> NearbyPublicReference {
        let manifest = try XCTUnwrap(NearbyPublicManifest(id: id, byteCount: bytes.count, sha256: digest))
        return NearbyPublicReference(entry: .init(manifest: manifest, title: "Fixture reference"),
                                     directory: directory, bundledFile: nil, availableCapacity: { _ in .max })
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
