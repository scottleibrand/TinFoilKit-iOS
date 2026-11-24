import Foundation
import XCTest
@testable import TinfoilKit

final class NearbyPublicReferenceTests: XCTestCase {
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
        XCTAssertTrue(recipient.canReceive())
        try recipient.receiveVerified(bytes)
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

        XCTAssertFalse(store.canReceive())
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

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
