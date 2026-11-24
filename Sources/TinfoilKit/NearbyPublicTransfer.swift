import Foundation
import Network

/// Exchanges a single catalog-pinned public reference. This channel has no private payloads.
@MainActor
final class NearbyPublicTransfer {
    private struct ActiveConnection {
        let connection: NWConnection
        let timeout: Task<Void, Never>
        var phase = ConnectionPhase.preparing
        var isTransferring: Bool { phase == .transferring }
    }

    private enum ConnectionPhase { case preparing, readingRequest, transferring }
    private enum Lifecycle { case running, draining, stopped }

    private static let request = Data(("TFK-PUBLIC-1 " + NearbyPublicReference.id).utf8)
    private let reference: NearbyPublicReference
    private let didReceive: (Data) -> Void
    private var inbound: [UUID: ActiveConnection] = [:]
    private var outbound: (id: UUID, active: ActiveConnection)?
    private var targets: [String: NWEndpoint] = [:]
    private var attempted: [String: ContinuousClock.Instant] = [:]
    private var retry: Task<Void, Never>?
    private var lifecycle = Lifecycle.running

    var activityDidChange: ((Bool) -> Void)?
    var hasActiveReceive: Bool { outbound?.active.isTransferring == true }
    var hasActiveTransfers: Bool {
        hasActiveReceive || inbound.values.contains(where: \.isTransferring)
    }

    init(reference: NearbyPublicReference, didReceive: @escaping (Data) -> Void) {
        self.reference = reference
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
        fetchNext()
    }

    func accept(_ connection: NWConnection) {
        guard lifecycle == .running, inbound.count < 4, let body = reference.loadVerified() else {
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
                        self?.readRequest(id, body: body, version: version)
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
    }

    private func fetchNext() {
        retry?.cancel()
        retry = nil
        guard lifecycle == .running, outbound == nil, !targets.isEmpty,
              reference.admission() == .receive else { return }
        let now = ContinuousClock.now
        let minimumInterval: Duration = .seconds(30)
        if let peer = targets.keys.sorted().first(where: { attempted[$0].map { now - $0 >= minimumInterval } ?? true }),
           let endpoint = targets[peer] {
            attempted[peer] = now
            let connection = NWConnection(to: endpoint, using: NearbyPublicTLS.clientParameters())
            let id = UUID()
            outbound = (id, track(connection) { [weak self] in self?.finishOutbound(id) })
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        if let connection, let version = NearbyPublicTLS.version(connection) {
                            self?.sendRequest(id, version: version)
                        } else { self?.finishOutbound(id) }
                    case .failed, .cancelled: self?.finishOutbound(id)
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
        } else if let oldest = attempted.values.min() {
            retry = Task { [weak self] in
                do { try await Task.sleep(until: oldest + minimumInterval, clock: .continuous) }
                catch { return }
                self?.fetchNext()
            }
        }
    }

    private func readRequest(_ id: UUID, body: Data, version: NearbyPublicTLS.Version) {
        guard lifecycle == .running, let active = inbound[id], active.phase == .preparing else { return }
        inbound[id]?.phase = .readingRequest
        let connection = active.connection
        let pin = NearbyPublicReference.resumePin
        let length = version == .resumable ? NearbyPublicResume.requestLength(pin: pin) : Self.request.count
        connection.receive(minimumIncompleteLength: length, maximumLength: length) {
            [weak self] request, _, _, error in
            DispatchQueue.main.async {
                guard let self, self.inbound[id]?.phase == .readingRequest else { return }
                guard error == nil, let request else {
                    self.finishInbound(id)
                    return
                }
                let offset = version == .resumable
                    ? NearbyPublicResume.offset(from: request, pin: pin, byteCount: body.count)
                    : (request == Self.request ? 0 : nil)
                guard let offset else {
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

    private func sendRequest(_ id: UUID, version: NearbyPublicTLS.Version) {
        guard lifecycle == .running, let pending = outbound,
              pending.id == id, !pending.active.isTransferring else { return }
        let previouslyActive = hasActiveTransfers
        outbound?.active.phase = .transferring
        notifyActivity(previouslyActive: previouslyActive)
        guard let outbound, outbound.id == id else { return }
        let connection = outbound.active.connection
        let prefix = version == .resumable ? reference.checkpoint() : Data()
        let request = version == .resumable
            ? NearbyPublicResume.request(pin: NearbyPublicReference.resumePin, offset: prefix.count) : Self.request
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
        let size = NearbyPublicReference.expectedByteCount
        let remaining = size - prefix.count
        let length = version == .resumable ? min(512, remaining) : remaining
        connection.receive(minimumIncompleteLength: length, maximumLength: length) {
            [weak self] bytes, _, isComplete, error in
            DispatchQueue.main.async {
                guard let self, self.outbound?.id == id else { return }
                guard error == nil, let bytes, !bytes.isEmpty, bytes.count <= remaining else {
                    self.finishOutbound(id)
                    return
                }
                let data = prefix + bytes
                if data.count == size {
                    do {
                        let installed = try self.reference.receiveVerified(data)
                        self.reference.removeCheckpoint()
                        if installed { self.didReceive(data) }
                    } catch NearbyPublicReference.StoreError.invalidReference {
                        // A bad prefix must not make every later attempt fail.
                        if version == .resumable { self.reference.removeCheckpoint() }
                    } catch {
                        // Keep the last prefix so an interrupted or low-space receive can retry.
                    }
                    self.finishOutbound(id)
                    return
                }
                guard version == .resumable else {
                    self.finishOutbound(id)
                    return
                }
                do {
                    try self.reference.saveCheckpoint(data)
                } catch {
                    self.finishOutbound(id)
                    return
                }
                if isComplete { self.finishOutbound(id) }
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
