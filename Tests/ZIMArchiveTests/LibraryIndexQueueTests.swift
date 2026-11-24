import Foundation
import XCTest
@testable import ZIMArchive

final class LibraryIndexQueueTests: XCTestCase {
    func testNewSmallerArchiveCanInterruptLargeArchiveAndThenReturnToIt() {
        let wikipedia = archive("Complete Wikipedia", bytes: 127_418_087_648)
        let water = archive("Water treatment", bytes: 20_924_451)
        XCTAssertFalse(LibraryIndexQueue.shouldPreempt(wikipedia, for: LibraryIndexQueue.next(
            in: [wikipedia], excluding: []
        )))
        let next = LibraryIndexQueue.next(in: [wikipedia, water], excluding: [])
        XCTAssertEqual(next?.id, water.id)
        XCTAssertTrue(LibraryIndexQueue.shouldPreempt(wikipedia, for: next))

        let resumed = LibraryIndexQueue.next(in: [water, wikipedia], excluding: [water.id])
        XCTAssertEqual(resumed?.id, wikipedia.id)
        XCTAssertFalse(LibraryIndexQueue.shouldPreempt(water, for: resumed))
    }

    func testEqualSizeDoesNotInterruptAnActiveArchive() {
        let first = archive("First", bytes: 1_024)
        let second = archive("Second", bytes: 1_024)
        XCTAssertFalse(LibraryIndexQueue.shouldPreempt(first, for: second))
        XCTAssertNil(LibraryIndexQueue.next(in: [first, second], excluding: [first.id, second.id]))
    }

    private func archive(_ title: String, bytes: Int64) -> InstalledArchive {
        InstalledArchive(id: UUID(), title: title, byteCount: bytes, pack: nil)
    }
}
