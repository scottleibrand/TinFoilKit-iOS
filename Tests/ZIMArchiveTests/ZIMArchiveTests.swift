import XCTest
@testable import ZIMArchive
import CryptoKit

private final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    var values: [Double] { lock.withLock { stored } }

    func append(_ value: Double) {
        lock.withLock { stored.append(value) }
    }
}

final class ZIMArchiveTests: XCTestCase {
    func testImportedArchiveVerificationDetectsCorruption() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let library = InstalledLibrary(directory: directory)
        let imported = try await library.importArchive(from: fixture)
        try await library.verifyArchive(imported)

        let installed = await library.fileURL(for: imported.id)
        var bytes = try Data(contentsOf: installed)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: installed, options: .atomic)
        XCTAssertGreaterThan(try ZIMArchive(fileURL: installed).entryCount, 0)

        do {
            try await library.verifyArchive(imported)
            XCTFail("Expected verification to reject a damaged checksum")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The ZIM archive does not match its embedded checksum.")
        }
    }

    func testDamagedManifestDoesNotHideOtherArchives() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let library = InstalledLibrary(directory: directory)
        let healthy = try await library.importArchive(from: fixture)
        let broken = try await library.importArchive(from: fixture)
        let brokenFolder = await library.fileURL(for: broken.id).deletingLastPathComponent()
        try Data("not json".utf8).write(to: brokenFolder.appendingPathComponent("manifest.json"))

        let inventory = try await InstalledLibrary(directory: directory).inventory()
        XCTAssertEqual(inventory.archives, [healthy])
        XCTAssertEqual(inventory.damaged, [broken.id])

        try await library.removeArchive(broken.id)
        let repaired = try await library.inventory()
        XCTAssertEqual(repaired.archives, [healthy])
        XCTAssertTrue(repaired.damaged.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: brokenFolder.path))
    }

    func testInterruptedImportIsRemovedOnNextLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let leftover = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data(count: 1024).write(to: leftover.appendingPathComponent("archive.zim"))
        let unrelated = directory.appendingPathComponent(".notes.partial")
        try Data().write(to: unrelated)

        let inventory = try await InstalledLibrary(directory: directory).inventory()
        XCTAssertTrue(inventory.archives.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testImportReportsProgressAndCanBeCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let library = InstalledLibrary(directory: directory)
        let reported = Fractions()
        try await library.importArchive(from: fixture) { reported.append($0) }
        XCTAssertEqual(reported.values.last, 1)
        XCTAssertEqual(reported.values, reported.values.sorted())

        let cancelled = Task { try await library.importArchive(from: fixture) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled import was installed")
        } catch is CancellationError {}
        let inventory = try await library.inventory()
        XCTAssertEqual(inventory.archives.count, 1)
        let hidden = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }
        XCTAssertTrue(hidden.isEmpty)
    }

    func testPackInstallCanMoveTheVerifiedDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let download = directory.appendingPathComponent("download.zim")
        try FileManager.default.copyItem(at: fixture, to: download)
        let pack = PublishedPack(
            id: "climate", title: "Climate test pack", version: "2024-06", source: fixture,
            sha256: "448327659c3981918da00f12f8427996f6bbc4efb4d5c14ba39704122483f0f4",
            sizeEstimate: 8_896_329, attribution: "Wikipedia contributors"
        )
        let library = InstalledLibrary(directory: directory.appendingPathComponent("Library"))
        let installed = try await library.installPack(pack, from: download, movingSource: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.path))
        let file = await library.fileURL(for: installed.id)
        XCTAssertEqual(try ZIMArchive(fileURL: file).mainArticle().path, "index")
    }


    func testPackUpdateKeepsOldEditionUntilReplacementIndexIsReadyAfterRelaunch() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let payload = try Data(contentsOf: fixture)
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let oldPack = PublishedPack(id: "update-fixture", title: "Fixture", version: "2026-06", source: fixture,
                                    sha256: checksum, sizeEstimate: Int64(payload.count), attribution: "Fixture")
        let newPack = PublishedPack(id: oldPack.id, title: oldPack.title, version: "2026-09", source: fixture,
                                    sha256: checksum, sizeEstimate: oldPack.sizeEstimate, attribution: oldPack.attribution)
        let libraryDirectory = directory.appendingPathComponent("Library")
        let library = InstalledLibrary(directory: libraryDirectory)
        let old = try await library.installPack(oldPack, from: fixture)
        let corrupt = directory.appendingPathComponent("corrupt.zim")
        try (payload + Data([1])).write(to: corrupt)

        do {
            try await library.installPack(newPack, from: corrupt, replacing: old.id)
            XCTFail("Expected the invalid download to fail verification")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"))
        }
        let afterFailure = try await library.archives()
        XCTAssertEqual(afterFailure, [old])

        let replacement = try await library.installPack(newPack, from: fixture, replacing: old.id)
        let reopened = InstalledLibrary(directory: libraryDirectory)
        let reopenedArchives = try await reopened.archives()
        XCTAssertEqual(Set(reopenedArchives.map(\.id)), [old.id, replacement.id])
        let pending = try XCTUnwrap(reopenedArchives.first { $0.replacesArchiveID == old.id })
        let earlyRemoval = try await reopened.finishUpdate(pending)
        XCTAssertNil(earlyRemoval)
        try await reopened.verifyArchive(old)

        let newURL = await reopened.fileURL(for: replacement.id)
        let index = ArticleIndex(archiveURL: newURL)
        try index.build(archiveURL: newURL) { _ in }
        let removed = try await reopened.finishUpdate(pending)
        XCTAssertEqual(removed, old.id)
        let remaining = try await reopened.archives()
        XCTAssertEqual(remaining, [replacement])
        XCTAssertFalse(try index.search("climate").isEmpty)
    }

    func testPackRepairRejectsBadDownloadsAndKeepsArchiveIdentity() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let payload = try Data(contentsOf: fixture)
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let pack = PublishedPack(id: "repair-fixture", title: "Fixture", version: "1", source: fixture,
                                 sha256: checksum, sizeEstimate: Int64(payload.count), attribution: "Fixture")
        let library = InstalledLibrary(directory: directory.appendingPathComponent("Library"))
        let archive = try await library.installPack(pack, from: fixture)
        let installedURL = await library.fileURL(for: archive.id)
        let candidate = directory.appendingPathComponent("bad.zim")
        try (payload + Data([0])).write(to: candidate)

        do {
            try await library.repairPack(pack, archiveID: archive.id, from: candidate)
            XCTFail("Expected bad checksum to reject the replacement")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"))
        }
        XCTAssertEqual(try Data(contentsOf: installedURL), payload)

        try (payload + Data([0])).write(to: installedURL)
        let downloaded = directory.appendingPathComponent("downloaded.zim")
        try FileManager.default.copyItem(at: fixture, to: downloaded)
        try await library.repairPack(pack, archiveID: archive.id, from: downloaded, movingSource: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloaded.path))
        try await library.verifyArchive(archive)
        let entries = try await library.archives()
        XCTAssertEqual(entries, [archive])
    }

    @MainActor
    func testSearchFindsCommittedBatchesBeforeIndexIsReady() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let library = InstalledLibrary(directory: directory)
        let archive = try await library.importArchive(from: fixture)
        let archiveURL = await library.fileURL(for: archive.id)
        let index = ArticleIndex(archiveURL: archiveURL)
        let builder = Task.detached {
            try index.build(archiveURL: archiveURL) { fraction in
                if fraction >= 0.12 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            try await builder.value
            XCTFail("Expected indexing to stop after committed batches")
        } catch is CancellationError {}
        XCTAssertFalse(index.isReady)
        XCTAssertTrue(try index.search("climate").isEmpty)
        XCTAssertFalse(try index.search("climate", includeIncomplete: true).isEmpty)

        let indexing = LibraryIndexing(library: library)
        await indexing.refresh()
        let partialRevision = indexing.searchRevision
        XCTAssertEqual(indexing.searchable, [archive.id])
        let deadline = ContinuousClock.now + .seconds(45)
        while indexing.hasPendingIndexes, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(index.isReady)
        XCTAssertEqual(indexing.searchable, [archive.id])
        XCTAssertGreaterThan(indexing.searchRevision, partialRevision)
        XCTAssertFalse(try index.search("climate").isEmpty)
    }

    @MainActor
    func testPackVerificationAndRemovalWhileIndexing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let payload = try Data(contentsOf: fixture)
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let pack = PublishedPack(id: "fixture", title: "Fixture", version: "1", source: fixture,
                                 sha256: checksum, sizeEstimate: Int64(payload.count), attribution: "Fixture")
        let library = InstalledLibrary(directory: directory)
        let installed = try await library.installPack(pack, from: fixture)
        try await library.verifyArchive(installed)
        let indexing = LibraryIndexing(library: library)
        await indexing.refresh()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while indexing.progress == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(indexing.progress?.id, installed.id)
        try await indexing.removeArchive(installed.id)
        let archives = try await library.archives()
        let archiveFile = await library.fileURL(for: installed.id)
        XCTAssertTrue(archives.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveFile.deletingLastPathComponent().path))
        XCTAssertFalse(indexing.searchable.contains(installed.id))
        XCTAssertNil(indexing.errors[installed.id])
    }

    @MainActor
    func testIndexingSurvivesTheSubmittingTaskBeingCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let library = InstalledLibrary(directory: directory)
        let installed = try await library.importArchive(from: fixture)
        let indexing = LibraryIndexing(library: library)
        let tabTask = Task {
            await indexing.refresh()
            try await Task.sleep(for: .seconds(60))
        }
        defer { tabTask.cancel() }

        let clock = ContinuousClock()
        let startDeadline = clock.now + .seconds(10)
        while indexing.progress == nil, clock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(indexing.progress?.id, installed.id)
        tabTask.cancel()

        let file = await library.fileURL(for: installed.id)
        let index = ArticleIndex(archiveURL: file)
        let finishDeadline = clock.now + .seconds(90)
        while !index.isReady, clock.now < finishDeadline, indexing.errors.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(index.isReady)
        XCTAssertTrue(indexing.searchable.contains(installed.id))
        XCTAssertFalse(try index.search("anthropogenic").isEmpty)
    }

    func testReadsArticleFromLocalWikipediaArchive() throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let archive = try ZIMArchive(fileURL: file)

        let article = try archive.mainArticle()
        XCTAssertEqual(article.path, "index")
        XCTAssertEqual(article.mimeType, "text/html")
        XCTAssertTrue(String(decoding: article.data, as: UTF8.self).localizedCaseInsensitiveContains("climate change"))
        XCTAssertEqual(try archive.resource(at: article.path).data, article.data)
        XCTAssertThrowsError(try archive.resource(at: "missing-entry-for-test"))
    }

    func testReportsInvalidArchive() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Invalid archive".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertThrowsError(try ZIMArchive(fileURL: file))
    }

    func testInstalledArchiveSurvivesReopeningLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let library = InstalledLibrary(directory: directory)
        let installed = try await library.importArchive(from: file)

        let reopened = InstalledLibrary(directory: directory)
        let archives = try await reopened.archives()
        XCTAssertEqual(archives, [installed])
        XCTAssertGreaterThan(installed.byteCount, 0)
        let copy = await reopened.fileURL(for: installed.id)
        XCTAssertNotEqual(copy, file)
        XCTAssertEqual(try ZIMArchive(fileURL: copy).mainArticle().path, "index")
    }

    func testFailedImportDoesNotAppearInLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("invalid.zim")
        try Data("Invalid archive".utf8).write(to: file)
        let storage = directory.appendingPathComponent("Library")
        let library = InstalledLibrary(directory: storage)

        do {
            try await library.importArchive(from: file)
            XCTFail("An invalid archive was accepted")
        } catch {}
        let archives = try await library.archives()
        XCTAssertTrue(archives.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storage.path).isEmpty)
    }

    func testFullTextSearchResumesForAnArchiveAboveOneGiB() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let file = directory.appendingPathComponent("large.zim")
        try makeSparseArchive(from: fixture, at: file)
        XCTAssertGreaterThan(try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize), 1 << 30)
        let index = ArticleIndex(archiveURL: file)
        let interrupted = Task.detached {
            try index.build(archiveURL: file) { progress in
                if progress > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            try await interrupted.value
            XCTFail("Indexing should have been interrupted after its first committed batch")
        } catch is CancellationError {}
        XCTAssertFalse(index.isReady)

        var firstProgress: Double?
        try index.build(archiveURL: file) { progress in
            if firstProgress == nil { firstProgress = progress }
        }
        XCTAssertGreaterThan(try XCTUnwrap(firstProgress), 0)
        XCTAssertLessThan(try XCTUnwrap(firstProgress), 1)

        let reopenedIndex = ArticleIndex(archiveURL: file)
        let matches = try reopenedIndex.search("anthropogenic")
        let match = try XCTUnwrap(matches.first {
            !$0.title.localizedCaseInsensitiveContains("anthropogenic")
                && $0.excerpt.localizedCaseInsensitiveContains("anthropogenic")
        })
        let article = try ZIMArchive(fileURL: file).resource(at: match.path)
        XCTAssertTrue(String(decoding: article.data, as: UTF8.self).localizedCaseInsensitiveContains("anthropogenic"))
    }

    private func makeSparseArchive(from fixture: URL, at file: URL) throws {
        // Move the trailing ZIM checksum past a sparse gap to exercise a large file without a large download.
        var bytes = try Data(contentsOf: fixture)
        bytes.removeLast(16)
        let checksumPosition = 1 << 30
        var position = UInt64(checksumPosition).littleEndian
        withUnsafeBytes(of: &position) { bytes.replaceSubrange(72..<80, with: $0) }
        try bytes.write(to: file)

        var checksum = Insecure.MD5()
        checksum.update(data: bytes)
        let zeros = Data(count: 1024 * 1024)
        var remaining = checksumPosition - bytes.count
        while remaining >= zeros.count {
            checksum.update(data: zeros)
            remaining -= zeros.count
        }
        checksum.update(data: zeros.prefix(remaining))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(checksumPosition))
        try handle.write(contentsOf: Data(checksum.finalize()))
    }

    func testPublisherVerificationPreservesInstalledEdition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let library = InstalledLibrary(directory: directory)
        let edition = PublishedPack(
            id: "climate", title: "Climate test pack", version: "2024-06", source: fixture,
            sha256: "448327659c3981918da00f12f8427996f6bbc4efb4d5c14ba39704122483f0f4",
            sizeEstimate: 8_896_329, attribution: "Wikipedia contributors"
        )
        let installed = try await library.installPack(edition, from: fixture)
        let duplicate = try await library.installPack(edition, from: fixture)
        XCTAssertEqual(duplicate, installed)

        let badUpdate = PublishedPack(
            id: edition.id, title: edition.title, version: "2024-07", source: fixture,
            sha256: String(repeating: "0", count: 64), sizeEstimate: edition.sizeEstimate, attribution: edition.attribution
        )
        do {
            try await library.installPack(badUpdate, from: fixture)
            XCTFail("An archive with a bad checksum was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"))
        }
        let archives = try await library.archives()
        XCTAssertEqual(archives, [installed])
        let installedURL = await library.fileURL(for: installed.id)
        XCTAssertEqual(try ZIMArchive(fileURL: installedURL).mainArticle().path, "index")
    }
}
