import CryptoKit
import Foundation
import XCTest
@testable import TinfoilKit

final class RegionalDownloadStateTests: XCTestCase {
    func testPersistedCheckpointChecksPrefixAndTrimsUncommittedTail() throws {
        let state = try makeState()
        defer { try? state.discard() }
        let asset = try makeAsset(state)
        let prefix = Data("abcd".utf8)
        try prefix.write(to: asset.file)
        try asset.save(offset: 4, validator: "\"original\"", hash: hash(prefix))
        try Data("abcdstale".utf8).write(to: asset.file)

        let reopened = RegionalDownloadState.Asset(file: asset.file, manifestSHA256: asset.manifestSHA256,
                                                  expected: asset.expected)
        let checkpoint = try XCTUnwrap(reopened.resume())
        XCTAssertEqual(checkpoint.offset, 4)
        XCTAssertEqual(checkpoint.validator, "\"original\"")
        XCTAssertEqual(try Data(contentsOf: asset.file), prefix)
    }

    func testRejectsStaleOrCorruptCheckpointsAndUnverifiedFile() throws {
        let state = try makeState()
        defer { try? state.discard() }
        let asset = try makeAsset(state)
        let prefix = Data("abcd".utf8)
        try prefix.write(to: asset.file)
        try asset.save(offset: 4, validator: "\"original\"", hash: hash(prefix))
        let mismatched = RegionalDownloadState.Asset(file: asset.file, manifestSHA256: String(repeating: "a", count: 64),
                                                     expected: asset.expected)
        XCTAssertNil(try mismatched.resume())
        try Data("xbcdef".utf8).write(to: asset.file)
        XCTAssertNil(try asset.resume())
        try Data("abc".utf8).write(to: asset.file)
        XCTAssertNil(try asset.resume())

        try prefix.write(to: asset.file)
        try asset.save(offset: 4, validator: "W/\"weak\"", hash: hash(prefix))
        XCTAssertNil(try asset.resume())
        try Data("abcdefghix".utf8).write(to: asset.file)
        XCTAssertFalse(try asset.verified())
        try Data("abcdefghij".utf8).write(to: asset.file)
        XCTAssertTrue(try asset.verified())
        try asset.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.file.path))
        XCTAssertNil(try asset.resume())
    }

    func testJobSurvivesReopeningAndKeepsItsCellularPolicy() throws {
        let state = try makeState()
        defer { try? state.discard() }
        let source = try RegionalBundleDownloadSource(
            url: "https://example.invalid/bundle/manifest.json", sha256: String(repeating: "b", count: 64)
        )
        var job = RegionalDownloadState.Job(source: source, cellular: false)
        job.started = true
        try state.save(job)
        let reopened = RegionalDownloadState(directory: state.directory)
        let loaded = try XCTUnwrap(reopened.job())
        XCTAssertEqual(loaded.manifestSHA256, source.sha256)
        XCTAssertFalse(loaded.cellular)
        XCTAssertTrue(loaded.started)

        try Data(repeating: 32, count: 16_385).write(to: state.jobFile)
        XCTAssertThrowsError(try reopened.job()) {
            XCTAssertEqual($0 as? RegionalBundleDownloadError, .invalidCheckpoint)
        }
        try reopened.discard()
        XCTAssertNil(try reopened.job())
    }

    func testCheckpointAndDiscardDoNotFollowSymbolicLinks() throws {
        let state = try makeState()
        defer { try? state.discard() }
        let asset = try makeAsset(state)
        let other = state.directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: other) }
        try Data("abcdefghij".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: asset.file, withDestinationURL: other)
        XCTAssertNil(try asset.resume())
        XCTAssertFalse(try asset.verified())
        try asset.reset()
        XCTAssertEqual(try Data(contentsOf: other), Data("abcdefghij".utf8))
    }

    private func makeState() throws -> RegionalDownloadState {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RegionalDownloadState(directory: directory)
    }

    private func makeAsset(_ state: RegionalDownloadState) throws -> RegionalDownloadState.Asset {
        let source = try RegionalBundleDownloadSource(
            url: "https://example.invalid/manifest.json", sha256: String(repeating: "b", count: 64)
        )
        let job = RegionalDownloadState.Job(source: source, cellular: false)
        let url = try XCTUnwrap(URL(string: "https://example.invalid/places.sqlite"))
        return state.asset(.init(filename: "places.sqlite", url: url, byteCount: 10,
                                 sha256: RegionalDownloadState.hex(hash(Data("abcdefghij".utf8)))),
                           job: job)
    }

    private func hash(_ data: Data) -> SHA256 {
        var hash = SHA256()
        hash.update(data: data)
        return hash
    }
}
