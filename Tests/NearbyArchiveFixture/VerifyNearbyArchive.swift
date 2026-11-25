import CryptoKit
import Foundation

@main
struct VerifyNearbyArchive {
    enum Failure: Error { case timedOut(String), invalidPartial }
    static let fixtureBytes: UInt64 = 1 << 30

    @MainActor
    static func main() async throws {
        let working = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = working.appendingPathComponent("source.zim")
        let received = working.appendingPathComponent("received.zim")
        let stage = working.appendingPathComponent("stage", isDirectory: true)
        let digest = try makeLargeFixture(source)
        let pin = NearbyPublicManifest(id: "archive-fixture", byteCount: Int(fixtureBytes), sha256: digest)!
        let largeOffset = UInt64(1) << 32 | 123
        precondition(NearbyArchiveRequest(NearbyArchiveRequest(pin: pin, offset: largeOffset).data)?.offset == largeOffset)
        precondition(NearbyArchiveRequest(Data(repeating: 0, count: NearbyArchiveRequest.length)) == nil)
        precondition(!NearbyArchiveRequest(pin: pin, offset: fixtureBytes).matches(pin))

        let sender = NearbyArchiveTransfer(catalog: .init(
            pins: [pin], needs: { _ in false }, source: { _ in source }, install: { _, _ in }
        ), directory: working.appendingPathComponent("sender-stage"))
        let worksheet = URL(fileURLWithPath: "Resources/NearbyPublic/household-check-in-v1.txt")
        let bundledReference = NearbyPublicReference(directory: working.appendingPathComponent("templates"),
                                                    bundledFile: worksheet)
        let server = NearbyDiscovery(publicReferences: [bundledReference], archiveTransfer: sender)
        server.start(publicSync: true)
        defer { server.stop() }

        let receivingCatalog = NearbyArchiveTransfer.Catalog(
            pins: [pin],
            needs: { _ in !FileManager.default.fileExists(atPath: received.path) },
            source: { _ in nil },
            install: { _, file in try FileManager.default.moveItem(at: file, to: received) }
        )
        let partial = stage.appendingPathComponent(digest).appendingPathExtension("zim")
        func partialBytes() -> UInt64 {
            (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.uint64Value ?? 0
        }
        let first = NearbyArchiveTransfer(catalog: receivingCatalog, directory: stage)
        let firstDiscovery = NearbyDiscovery(publicReferences: [], archiveTransfer: first)
        firstDiscovery.start(publicSync: true)
        defer { firstDiscovery.stop() }
        try await wait("initial prefix", for: { partialBytes() >= 1_048_576 })
        firstDiscovery.stop()
        try await wait("interrupted links closed", for: { !first.hasActiveTransfers && !sender.hasActiveTransfers })
        let checkpoint = partialBytes()
        guard checkpoint >= 1_048_576, checkpoint < fixtureBytes else { throw Failure.invalidPartial }

        let reopened = NearbyArchiveTransfer(catalog: receivingCatalog, directory: stage)
        let reopenedDiscovery = NearbyDiscovery(publicReferences: [], archiveTransfer: reopened)
        reopenedDiscovery.start(publicSync: true)
        defer { reopenedDiscovery.stop() }
        try await wait("resumed receive", for: { reopened.activeReceiveID != nil })
        reopenedDiscovery.finishTransfersWithoutDiscovery()
        precondition(!reopenedDiscovery.isRunning)
        try await wait("verified install", seconds: 120, for: { FileManager.default.fileExists(atPath: received.path) && !reopened.hasActiveTransfers })
        precondition(reopened.receivedIDs.contains("archive-" + digest))
        precondition(!FileManager.default.fileExists(atPath: partial.path))
        let finalSize = try FileManager.default.attributesOfItem(atPath: received.path)[.size] as? NSNumber
        precondition(finalSize?.uint64Value == fixtureBytes)
        print("Transferred \(fixtureBytes) verified bytes over TLS, resumed at \(checkpoint), and finished while draining.")

        let templateOnly = NearbyPublicReference(directory: working.appendingPathComponent("template-client"))
        let templateClient = NearbyDiscovery(publicReferences: [templateOnly])
        templateClient.start(publicSync: true)
        defer { templateClient.stop() }
        try await wait("template negotiation with an archive-capable peer", for: {
            templateClient.publicReferences.contains { $0.id == bundledReference.entry.id }
        })
        precondition(templateOnly.loadVerified() == bundledReference.loadVerified())
        print("A template-only client negotiated the existing protocol with the archive-capable peer.")
    }

    @MainActor
    private static func wait(_ description: String, seconds: Int = 15, for condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timedOut(description) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Sparse on disk before the transfer. Mark each end so duplicate or reordered ranges fail the pin.
    private static func makeLargeFixture(_ file: URL) throws -> String {
        let header = Data(repeating: 0x47, count: NearbyArchiveFiles.chunkBytes)
        let trailer = Data(repeating: 0xe2, count: NearbyArchiveFiles.chunkBytes)
        let zeroes = Data(repeating: 0, count: NearbyArchiveFiles.chunkBytes)
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.write(contentsOf: header)
        try writer.seek(toOffset: fixtureBytes - UInt64(trailer.count))
        try writer.write(contentsOf: trailer)
        try writer.synchronize()
        var hash = SHA256()
        hash.update(data: header)
        for _ in 0..<(Int(fixtureBytes) / zeroes.count - 2) { hash.update(data: zeroes) }
        hash.update(data: trailer)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
