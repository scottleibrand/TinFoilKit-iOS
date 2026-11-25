import Foundation
import Network

struct NearbyArchiveRequest: Equatable, Sendable {
    static let length = 72
    let digest: String
    let offset: UInt64

    init(pin: NearbyPublicManifest, offset: UInt64) {
        digest = pin.sha256
        self.offset = offset
    }

    init?(_ data: Data) {
        guard data.count == Self.length,
              let digest = String(bytes: data.prefix(64), encoding: .ascii),
              NearbyPublicManifest(id: "archive", byteCount: 1, sha256: digest) != nil else { return nil }
        self.digest = digest
        offset = data.suffix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    var data: Data {
        var offset = offset.bigEndian
        return Data(digest.utf8) + withUnsafeBytes(of: &offset) { Data($0) }
    }

    func matches(_ pin: NearbyPublicManifest) -> Bool {
        digest == pin.sha256 && offset < UInt64(pin.byteCount)
    }
}

/// The file path has its own negotiated protocol. Template peers keep their existing framing.
@MainActor
final class NearbyArchiveTransfer {
    struct Catalog {
        let pins: [NearbyPublicManifest]
        let needs: @MainActor (NearbyPublicManifest) async -> Bool
        let source: @MainActor (NearbyPublicManifest) async -> URL?
        let install: @MainActor (NearbyPublicManifest, URL) async throws -> Void
    }

    private let catalog: Catalog
    private let files: NearbyArchiveFiles
    private var targets: [String: NWEndpoint] = [:]
    private var attempted: [String: [String: ContinuousClock.Instant]] = [:]
    private var retry: Task<Void, Never>?
    private var outbound: Link?
    private var outboundTask: Task<Void, Never>?
    private var inbound: Link?
    private var receivingPin: NearbyPublicManifest?
    private var draining = false
    private var cleanedStage = false
    private(set) var receivedIDs: Set<String> = []
    var activityDidChange: (() -> Void)?

    var hasActiveTransfers: Bool { inbound?.active == true || receivingPin != nil }
    var activeReceiveID: String? { receivingPin.map(Self.receiveID) }

    init(catalog: Catalog, directory: URL) {
        self.catalog = catalog
        files = NearbyArchiveFiles(directory: directory)
    }

    func updateTargets(_ targets: [String: NWEndpoint]) {
        guard !draining else { return }
        self.targets = targets
        attempted = attempted.filter { targets[$0.key] != nil }
        schedule()
    }

    func beginDraining() {
        draining = true
        targets = [:]
        retry?.cancel()
        retry = nil
        if inbound?.active != true { inbound?.close() }
        if receivingPin == nil { outbound?.close() }
    }

    func resume() { draining = false }

    func stop() {
        beginDraining()
        inbound?.close()
        outbound?.close()
        outboundTask?.cancel()
    }

    func acceptReady(_ connection: NWConnection) {
        guard !draining, inbound == nil else {
            connection.cancel()
            return
        }
        let link = Link(connection)
        inbound = link
        Task { @MainActor in
            defer {
                link.close()
                self.inbound = nil
                self.activityDidChange?()
            }
            await self.serve(link)
        }
    }

    private func serve(_ link: Link) async {
        let header = await link.read(NearbyArchiveRequest.length)
        guard header.error == nil, let bytes = header.data, let request = NearbyArchiveRequest(bytes),
              let pin = catalog.pins.first(where: request.matches),
              let file = await catalog.source(pin), !draining, !link.closed,
              let reader = try? NearbyArchiveReader(file: file, byteCount: UInt64(pin.byteCount),
                                                     offset: request.offset) else { return }
        link.active = true
        activityDidChange?()
        guard await link.write(Data([1])) else { return }
        var remaining = UInt64(pin.byteCount) - request.offset
        while remaining > 0, !link.closed {
            guard let chunk = try? await reader.nextChunk(), !chunk.isEmpty,
                  UInt64(chunk.count) <= remaining else { return }
            remaining -= UInt64(chunk.count)
            guard await link.write(chunk, final: remaining == 0) else { return }
        }
        if !link.closed { _ = await link.read(1) }
    }

    private func schedule() {
        guard !draining, outbound == nil, !targets.isEmpty, !catalog.pins.isEmpty else { return }
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchNext()
        }
    }

    private func fetchNext() async {
        if !cleanedStage {
            try? await files.prune(keeping: Set(catalog.pins.map(\.sha256)))
            cleanedStage = true
        }
        let interval: Duration = .seconds(30)
        var next: ContinuousClock.Instant?
        for pin in catalog.pins {
            guard !Task.isCancelled, !draining else { return }
            guard await catalog.needs(pin) else { continue }
            guard !Task.isCancelled, !draining else { return }
            for peer in targets.keys.sorted() {
                guard let endpoint = targets[peer] else { continue }
                let now = ContinuousClock.now
                if let attempt = attempted[peer]?[pin.sha256], now - attempt < interval {
                    let deadline = attempt + interval
                    next = next.map { min($0, deadline) } ?? deadline
                    continue
                }
                attempted[peer, default: [:]][pin.sha256] = now
                let link = Link(NWConnection(to: endpoint, using: NearbyPublicTLS.clientParameters(archive: true)))
                outbound = link
                retry = nil
                outboundTask = Task { @MainActor in
                    await self.fetch(pin, link: link)
                    link.close()
                    self.outbound = nil
                    self.outboundTask = nil
                    self.receivingPin = nil
                    self.activityDidChange?()
                    self.schedule()
                }
                return
            }
        }
        // Catalog state can change without a new Bonjour event.
        let deadline = next ?? (ContinuousClock.now + interval)
        do { try await Task.sleep(until: deadline, clock: .continuous) }
        catch { return }
        schedule()
    }

    private func fetch(_ pin: NearbyPublicManifest, link: Link) async {
        let total = UInt64(pin.byteCount)
        do {
            var offset = try await files.prepare(digest: pin.sha256, byteCount: total)
            guard !draining, !link.closed else { return }
            if offset < total {
                guard await link.connect(), !draining,
                      await link.write(NearbyArchiveRequest(pin: pin, offset: offset).data) else { return }
                let answer = await link.read(1)
                guard answer.data == Data([1]), answer.error == nil, !answer.complete, !draining, !link.closed else { return }
                receivedIDs.remove(Self.receiveID(pin))
                receivingPin = pin
                activityDidChange?()
                while offset < total, !link.closed {
                    let length = Int(min(UInt64(NearbyArchiveFiles.chunkBytes), total - offset))
                    let reply = await link.read(length)
                    guard let bytes = reply.data, !bytes.isEmpty, bytes.count <= length else { return }
                    offset = try await files.append(bytes, at: offset, digest: pin.sha256, byteCount: total)
                    if offset < total, reply.complete || reply.error != nil { return }
                }
            }
            // The trusted size frames the archive. A TLS peer can keep the stream open after sending it.
            guard offset == total, !link.closed else { return }
            link.finishNetwork()
            let file = try await files.verifiedFile(digest: pin.sha256, byteCount: total)
            guard !link.closed else { return }
            try await catalog.install(pin, file)
            receivedIDs.insert(Self.receiveID(pin))
        } catch {
            // Partial bytes remain available for a later peer or foreground run.
        }
    }

    private static func receiveID(_ pin: NearbyPublicManifest) -> String { "archive-" + pin.sha256 }

    /// Serializes operations on one Network.framework connection and expires idle work.
    @MainActor
    private final class Link {
        let connection: NWConnection
        var active = false
        private(set) var closed = false
        private var idle: Task<Void, Never>?
        private var connecting: CheckedContinuation<Bool, Never>?

        init(_ connection: NWConnection) { self.connection = connection }

        deinit {
            idle?.cancel()
            connection.cancel()
        }

        func connect() async -> Bool {
            guard !closed else { return false }
            return await withCheckedContinuation { pending in
                connecting = pending
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.connected(NearbyPublicTLS.version(self.connection) == .archive)
                        case .failed, .cancelled:
                            self.connected(false)
                        default:
                            break
                        }
                    }
                }
                renewDeadline()
                connection.start(queue: .main)
            }
        }

        private func connected(_ ready: Bool) {
            let pending = connecting
            connecting = nil
            pending?.resume(returning: ready)
        }

        func read(_ length: Int) async -> (data: Data?, complete: Bool, error: NWError?) {
            guard !closed else { return (nil, true, nil) }
            renewDeadline()
            return await withCheckedContinuation { pending in
                connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, complete, error in
                    pending.resume(returning: (data, complete, error))
                }
            }
        }

        func write(_ data: Data, final: Bool = false) async -> Bool {
            guard !closed else { return false }
            renewDeadline()
            return await withCheckedContinuation { pending in
                connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                                completion: .contentProcessed { pending.resume(returning: $0 == nil) })
            }
        }

        // No network timeout applies while hashing or installing the complete file.
        func finishNetwork() {
            idle?.cancel()
            idle = nil
        }

        func close() {
            closed = true
            finishNetwork()
            connected(false)
            connection.cancel()
        }

        private func renewDeadline() {
            idle?.cancel()
            idle = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                self?.close()
            }
        }
    }
}
