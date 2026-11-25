import CryptoKit
import Foundation
import XCTest
@testable import TinfoilKit

final class NearbyArchiveFilesTests: XCTestCase {
    func testInterruptedTransferResumesFromDiskAndVerifiesTheCompleteArchive() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data((0..<(NearbyArchiveFiles.chunkBytes * 2 + 97)).map { UInt8($0 % 251) })
        let digest = sha256(bytes)
        let size = UInt64(bytes.count)
        let prefix = bytes.prefix(NearbyArchiveFiles.chunkBytes)
        let first = NearbyArchiveFiles(directory: directory)
        let freshOffset = try await first.prepare(digest: digest, byteCount: size, availableBytes: Int64.max)
        XCTAssertEqual(freshOffset, 0)
        let firstOffset = try await first.append(prefix, at: freshOffset, digest: digest, byteCount: size)
        await expect(.incomplete) { _ = try await first.verifiedFile(digest: digest, byteCount: size) }
        XCTAssertEqual(firstOffset, UInt64(prefix.count))

        let cancelledWrite = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await first.append(Data([0]), at: firstOffset, digest: digest, byteCount: size)
        }
        cancelledWrite.cancel()
        do {
            _ = try await cancelledWrite.value
            XCTFail("A cancelled transfer should leave the previous prefix intact")
        } catch is CancellationError {}

        let reopened = NearbyArchiveFiles(directory: directory)
        let resumedOffset = try await reopened.prepare(digest: digest, byteCount: size, availableBytes: Int64.max)
        XCTAssertEqual(resumedOffset, firstOffset)
        let source = directory.appendingPathComponent("source.zim")
        try bytes.write(to: source)
        let reader = try NearbyArchiveReader(file: source, byteCount: size, offset: resumedOffset)
        var offset = resumedOffset
        while let chunk = try await reader.nextChunk() {
            XCTAssertLessThanOrEqual(chunk.count, NearbyArchiveFiles.chunkBytes)
            offset = try await reopened.append(chunk, at: offset, digest: digest, byteCount: size)
        }

        XCTAssertEqual(offset, size)
        let file = try await reopened.verifiedFile(digest: digest, byteCount: size)
        XCTAssertEqual(file.pathExtension, "zim")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testRejectsBadBytesAndUnsafePaths() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = NearbyArchiveFiles(directory: directory)
        let digest = sha256(Data([1, 2, 3]))
        let size: UInt64 = 3

        await expect(.invalidEdition) {
            _ = try await files.prepare(digest: "../outside", byteCount: size, availableBytes: Int64.max)
        }
        await expect(.insufficientStorage) {
            _ = try await files.prepare(digest: digest, byteCount: size, availableBytes: 0)
        }
        _ = try await files.prepare(digest: digest, byteCount: size, availableBytes: Int64.max)
        _ = try await files.append(Data([4]), at: 0, digest: digest, byteCount: size)
        await expect(.invalidOffset) {
            _ = try await files.append(Data([2, 3]), at: 0, digest: digest, byteCount: size)
        }
        await expect(.invalidOffset) {
            _ = try await files.append(Data([2, 3, 4]), at: 1, digest: digest, byteCount: size)
        }
        _ = try await files.append(Data([2, 3]), at: 1, digest: digest, byteCount: size)
        await expect(.checksumMismatch) { _ = try await files.verifiedFile(digest: digest, byteCount: size) }
        let offset = try await files.prepare(digest: digest, byteCount: size, availableBytes: Int64.max)
        XCTAssertEqual(offset, 0)

        let target = directory.appendingPathComponent("source.zim")
        try Data([1, 2, 3]).write(to: target)
        let symlink = directory.appendingPathComponent(digest).appendingPathExtension("zim")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        await expect(.invalidFile) {
            _ = try await files.prepare(digest: digest, byteCount: size, availableBytes: Int64.max)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 3]))
    }

    func testReaderCanSeekBeyondFourGiBWithoutLoadingThePrefix() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sparse.zim")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let offset = UInt64(UInt32.max) + 513
        let tail = Data([39, 52, 88, 104])
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: offset)
        try file.seek(toOffset: offset)
        try file.write(contentsOf: tail)
        try file.close()

        let reader = try NearbyArchiveReader(file: source, byteCount: offset + UInt64(tail.count), offset: offset)
        let first = try await reader.nextChunk()
        let next = try await reader.nextChunk()
        XCTAssertEqual(first, tail)
        XCTAssertNil(next)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func expect(_ expected: NearbyArchiveFiles.TransferError, file: StaticString = #filePath, line: UInt = #line,
                        operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? NearbyArchiveFiles.TransferError, expected, file: file, line: line)
        }
    }
}
