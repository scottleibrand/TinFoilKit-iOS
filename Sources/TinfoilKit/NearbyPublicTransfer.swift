import Foundation
import Network

/// Exchanges catalog-pinned public references. This channel has no private payloads.
@MainActor
final class NearbyPublicTransfer {
    private struct ActiveConnection {
        let connection: NWConnection
        let timeout: Task<Void, Never>
        var phase = ConnectionPhase.preparing
        var isTransferring: Bool { phase == .transferring }
    }

    private struct OutboundConnection {
        let id: UUID
        let peer: String
        let reference: NearbyPublicReference
        var active: ActiveConnection
    }

    private enum ConnectionPhase { case preparing, readingRequest, transferring }
    private enum Lifecycle { case running, draining, stopped }

    private static let request = Data(("TFK-PUBLIC-1 " + NearbyPublicReference.id).utf8)
    private let references: [NearbyPublicReference]
    private let didReceive: (NearbyPublicReference.Entry, Data) -> Void
    private var inbound: [UUID: ActiveConnection] = [:]
    private var outbound: OutboundConnection?
    private var targets: [String: NWEndpoint] = [:]
    private var attempted: [String: [String: ContinuousClock.Instant]] = [:]
    private var legacyPeers: Set<String> = []
    private var retry: Task<Void, Never>?
    private var lifecycle = Lifecycle.running

    var activityDidChange: ((Bool) -> Void)?
    var hasActiveReceive: Bool { outbound?.active.isTransferring == true }
    var hasActiveTransfers: Bool {
        hasActiveReceive || inbound.values.contains(where: \.isTransferring)
    }

    init(references: [NearbyPublicReference], didReceive: @escaping (NearbyPublicReference.Entry, Data) -> Void) {
        self.references = references
        self.didReceive = didReceive
    }

    deinit {
        retry?.cancel()
        outbound?.active.timeout.cancel()
        outbound?.active.connection.cancel()
        for active in inbound.values {
            active.timeout.cancel()
            active.connection.cancel()
        }
    }

    func updateTargets(_ next: [String: NWEndpoint]) {
        guard lifecycle == .running else { return }
        targets = next
        attempted = attempted.filter { targets[$0.key] != nil }
        legacyPeers.formIntersection(targets.keys)
        fetchNext()
    }

    func accept(_ connection: NWConnection) {
        guard lifecycle == .running, inbound.count < 4 else {
            connection.cancel()
            return
        }
        let id = UUID()
        inbound[id] = track(connection) { [weak self] in self?.finishInbound(id) }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    if let connection, let version = NearbyPublicTLS.version(connection) {
                        self?.readRequest(id, version: version)
                    } else { self?.finishInbound(id) }
                case .failed, .cancelled: self?.finishInbound(id)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    /// Let only negotiated public transfers finish, using their original deadlines.
    func beginDraining() {
        guard lifecycle == .running else { return }
        lifecycle = .draining
        discardNewWork()
        if let outbound, !outbound.active.isTransferring { finishOutbound(outbound.id) }
        let pending = inbound.filter { !$0.value.isTransferring }
        for id in pending.keys { finishInbound(id) }
    }

    func resume() {
        guard lifecycle == .draining else { return }
        lifecycle = .running
    }

    func stop() {
        lifecycle = .stopped
        discardNewWork()
        if let outbound { finishOutbound(outbound.id) }
        for id in Array(inbound.keys) { finishInbound(id) }
    }

    private func discardNewWork() {
        retry?.cancel()
        retry = nil
        targets.removeAll()
        attempted.removeAll()
        legacyPeers.removeAll()
    }

    private func fetchNext() {
        retry?.cancel()
        retry = nil
        guard lifecycle == .running, outbound == nil, !targets.isEmpty else { return }
        let now = ContinuousClock.now
        let minimumInterval: Duration = .seconds(30)
        let peers = targets.keys.sorted()
        var retryAt: ContinuousClock.Instant?
        for reference in references where reference.admission() == .receive {
            for peer in peers where reference.entry.id == NearbyPublicReference.id || !legacyPeers.contains(peer) {
                guard let endpoint = targets[peer] else { continue }
                if let previous = attempted[peer]?[reference.entry.id], now - previous < minimumInterval {
                    let deadline = previous + minimumInterval
                    retryAt = retryAt.map { min($0, deadline) } ?? deadline
                    continue
                }
                attempted[peer, default: [:]][reference.entry.id] = now
                connect(to: endpoint, peer: peer, reference: reference)
                return
            }
        }
        if let retryAt {
            retry = Task { [weak self] in
                do { try await Task.sleep(until: retryAt, clock: .continuous) }
                catch { return }
                self?.fetchNext()
            }
        }
    }

    private func connect(to endpoint: NWEndpoint, peer: String, reference: NearbyPublicReference) {
        let connection = NWConnection(to: endpoint, using: NearbyPublicTLS.clientParameters())
        let id = UUID()
        let active = track(connection) { [weak self] in self?.finishOutbound(id) }
        outbound = OutboundConnection(id: id, peer: peer, reference: reference, active: active)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    if let connection, let version = NearbyPublicTLS.version(connection) {
                        self?.sendRequest(id, version: version)
                    } else { self?.finishOutbound(id) }
                case .failed, .cancelled:
                    // An outstanding receive can still deliver its last bytes with the error.
                    // Transfer callbacks or the existing deadline will close this connection.
                    if self?.outbound?.active.isTransferring != true { self?.finishOutbound(id) }
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func readRequest(_ id: UUID, version: NearbyPublicTLS.Version) {
        guard lifecycle == .running, let active = inbound[id], active.phase == .preparing else { return }
        inbound[id]?.phase = .readingRequest
        let connection = active.connection
        let pin = NearbyPublicReference.resumePin
        let length = switch version {
        case .original: Self.request.count
        case .resumable: NearbyPublicResume.requestLength(pin: pin)
        case .catalog: NearbyPublicCatalogRequest.byteCount
        }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) {
            [weak self] request, _, _, error in
            DispatchQueue.main.async {
                guard let self, self.inbound[id]?.phase == .readingRequest else { return }
                guard error == nil, let request else {
                    self.finishInbound(id)
                    return
                }
                guard let (body, offset) = self.response(to: request, version: version) else {
                    self.finishInbound(id)
                    return
                }
                let previouslyActive = self.hasActiveTransfers
                self.inbound[id]?.phase = .transferring
                self.notifyActivity(previouslyActive: previouslyActive)
                guard self.inbound[id] != nil else { return }
                connection.send(content: Data(body.dropFirst(offset)), contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self, self.inbound[id] != nil else { return }
                        if error != nil {
                            self.finishInbound(id)
                            return
                        }
                        // Keep the TLS connection alive until the peer finishes or the deadline expires.
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                            DispatchQueue.main.async { self?.finishInbound(id) }
                        }
                    }
                })
            }
        }
    }

    private func response(to request: Data, version: NearbyPublicTLS.Version) -> (Data, Int)? {
        let id: String
        let offset: Int
        switch version {
        case .original:
            guard request == Self.request else { return nil }
            id = NearbyPublicReference.id
            offset = 0
        case .resumable:
            guard let value = NearbyPublicResume.offset(from: request, pin: NearbyPublicReference.resumePin,
                                                       byteCount: NearbyPublicReference.expectedByteCount) else { return nil }
            id = NearbyPublicReference.id
            offset = value
        case .catalog:
            guard let match = NearbyPublicCatalogRequest.match(request, in: references.map(\.entry.manifest)) else { return nil }
            id = match.id
            offset = match.offset
        }
        guard let reference = references.first(where: { $0.entry.id == id }),
              let bytes = reference.loadVerified() else { return nil }
        return (bytes, offset)
    }

    private func sendRequest(_ id: UUID, version: NearbyPublicTLS.Version) {
        guard lifecycle == .running, let pending = outbound,
              pending.id == id, !pending.active.isTransferring else { return }
        let reference = pending.reference
        if version != .catalog {
            legacyPeers.insert(pending.peer)
            guard reference.entry.id == NearbyPublicReference.id else {
                finishOutbound(id)
                return
            }
        }
        let previouslyActive = hasActiveTransfers
        outbound?.active.phase = .transferring
        notifyActivity(previouslyActive: previouslyActive)
        guard let outbound, outbound.id == id else { return }
        let connection = outbound.active.connection
        let prefix = version == .original ? Data() : reference.checkpoint()
        let request = switch version {
        case .original: Self.request
        case .resumable: NearbyPublicResume.request(pin: NearbyPublicReference.resumePin, offset: prefix.count)
        case .catalog: NearbyPublicCatalogRequest.request(for: reference.entry.manifest, offset: prefix.count)
        }
        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            DispatchQueue.main.async {
                guard self?.outbound?.id == id else { return }
                if error == nil {
                    self?.readReference(id, from: connection, prefix: prefix, version: version)
                }
                else { self?.finishOutbound(id) }
            }
        })
    }

    private func readReference(_ id: UUID, from connection: NWConnection, prefix: Data,
                               version: NearbyPublicTLS.Version) {
        guard let outbound, outbound.id == id else { return }
        let reference = outbound.reference
        let size = reference.entry.manifest.byteCount
        let remaining = size - prefix.count
        let length = version == .original ? remaining : min(512, remaining)
        connection.receive(minimumIncompleteLength: length, maximumLength: length) {
            [weak self] bytes, _, isComplete, error in
            DispatchQueue.main.async {
                guard let self, self.outbound?.id == id else { return }
                guard let bytes, !bytes.isEmpty, bytes.count <= length else {
                    self.finishOutbound(id)
                    return
                }
                let data = prefix + bytes
                if data.count == size {
                    do {
                        let installed = try reference.receiveVerified(data)
                        reference.removeCheckpoint()
                        if installed { self.didReceive(reference.entry, data) }
                    } catch NearbyPublicReference.StoreError.invalidReference {
                        // A bad prefix must not make every later attempt fail.
                        if version != .original { reference.removeCheckpoint() }
                    } catch {
                        // Keep the last prefix so an interrupted or low-space receive can retry.
                    }
                    self.finishOutbound(id)
                    return
                }
                guard version != .original else {
                    self.finishOutbound(id)
                    return
                }
                do {
                    try reference.saveCheckpoint(data)
                } catch {
                    self.finishOutbound(id)
                    return
                }
                if isComplete || error != nil { self.finishOutbound(id) }
                else { self.readReference(id, from: connection, prefix: data, version: version) }
            }
        }
    }

    private func track(_ connection: NWConnection, onTimeout: @escaping () -> Void) -> ActiveConnection {
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(8)) }
            catch { return }
            onTimeout()
        }
        return ActiveConnection(connection: connection, timeout: timeout)
    }

    private func finishInbound(_ id: UUID) {
        let previouslyActive = hasActiveTransfers
        guard let active = inbound.removeValue(forKey: id) else { return }
        active.timeout.cancel()
        active.connection.cancel()
        notifyActivity(previouslyActive: previouslyActive)
    }

    private func finishOutbound(_ id: UUID) {
        guard let current = outbound, current.id == id else { return }
        let previouslyActive = hasActiveTransfers
        outbound = nil
        current.active.timeout.cancel()
        current.active.connection.cancel()
        notifyActivity(previouslyActive: previouslyActive)
        fetchNext()
    }

    private func notifyActivity(previouslyActive: Bool) {
        let active = hasActiveTransfers
        if previouslyActive != active { activityDidChange?(active) }
    }
}
