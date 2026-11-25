import Foundation
import XCTest
@testable import TinfoilKit

final class OfflineChatPhotoLimitsTests: XCTestCase {
    func testValidatesFileBeforeDecoding() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try OfflineChatPhotoLimits.validate(file: directory)) {
            XCTAssertEqual($0 as? OfflineChatPhotoLimits.ImportError, .invalidPhoto)
        }
        let file = directory.appendingPathComponent("photo.jpg")
        try Data([0]).write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.truncate(atOffset: 32 * 1024 * 1024)
        try OfflineChatPhotoLimits.validate(file: file)
        try writer.truncate(atOffset: 32 * 1024 * 1024 + 1)
        XCTAssertThrowsError(try OfflineChatPhotoLimits.validate(file: file)) {
            XCTAssertEqual($0 as? OfflineChatPhotoLimits.ImportError, .tooLarge)
        }
    }

    func testValidatesDimensionsWithoutOverflow() throws {
        try OfflineChatPhotoLimits.validate(width: 10_000, height: 10_000)
        XCTAssertThrowsError(try OfflineChatPhotoLimits.validate(width: 0, height: 10_000)) {
            XCTAssertEqual($0 as? OfflineChatPhotoLimits.ImportError, .invalidPhoto)
        }
        XCTAssertThrowsError(try OfflineChatPhotoLimits.validate(width: .max, height: .max)) {
            XCTAssertEqual($0 as? OfflineChatPhotoLimits.ImportError, .tooLarge)
        }
    }

    func testCancellationStopsBeforeReadingTheFile() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try OfflineChatPhotoLimits.validate(file: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        }
        do {
            try await task.value
            XCTFail("Expected cancellation before opening the file")
        } catch is CancellationError {}
    }
}
