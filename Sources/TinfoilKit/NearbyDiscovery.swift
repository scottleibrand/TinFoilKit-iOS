import Combine
import Foundation
import Network

/// A foreground discovery session. Bonjour carries only a rotating random identifier.
@MainActor
final class NearbyDiscovery: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case discovering
        case waiting(String)
        case permissionDenied
        case failed(String)
    }

    struct Peer: Identifiable, Equatable, Sendable {
        let id: String
    }

    nonisolated static let serviceType = "_tfk-nearby._tcp"
    private nonisolated static let instancePrefix = "tfk-v1-"
    private nonisolated static let domain = "local."
    private nonisolated static let peerLimit = 32

    @Published private(set) var state: State = .idle
    @Published private(set) var localID: String?
    @Published private(set) var peers: [Peer] = []
    struct PublicReference: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    @Published private(set) var publicReferences: [PublicReference] = []
    var isRunning: Bool { browser != nil }
    var hasActivePublicTransfer: Bool { publicTransfer?.hasActiveTransfers == true }
    var hasActivePublicReceive: Bool { publicTransfer?.hasActiveReceive == true }
    var activityDidChange: ((Bool) -> Void)?

    private let references: [NearbyPublicReference]
    private var publicSyncEnabled = false
    private var publicTransfer: NearbyPublicTransfer?
    private let queue = DispatchQueue(label: "org.tinfoilkit.nearby-discovery")
    private var generation = UUID()
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var rotation: Task<Void, Never>?
    private var ready: Set<Phase> = []
    private var waiting: [Phase: State] = [:]
    private var recentLocalIDs: [String] = []

    init(publicReferences: [NearbyPublicReference] = NearbyPublicReference.catalogReferences) {
        references = publicReferences
        self.publicReferences = publicReferences.compactMap { reference in
            guard let data = reference.loadVerified(), let text = String(data: data, encoding: .utf8) else { return nil }
            return PublicReference(id: reference.entry.id, title: reference.entry.title, text: text)
        }
    }

    deinit {
        rotation?.cancel()
        browser?.cancel()
        listener?.cancel()
    }

    func start(publicSync enabled: Bool? = nil) {
        if let enabled, enabled != publicSyncEnabled {
            stop()
            publicSyncEnabled = enabled
        }
        guard !isRunning else { return }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let generation = self.generation

        let listener: NWListener
        do {
            let parameters = try publicSyncEnabled ? NearbyPublicTLS.listenerParameters() : Self.localParameters()
            parameters.acceptLocalOnly = true
            listener = try NWListener(using: parameters)
        } catch {
            state = Self.problem(for: error, terminal: true)
            return
        }
        listener.service = NWListener.Service(
            name: Self.instancePrefix + id, type: Self.serviceType, domain: Self.domain
        )
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async {
                guard let self, self.generation == generation, let transfer = self.publicTransfer else {
                    connection.cancel()
                    return
                }
                transfer.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] update in
            DispatchQueue.main.async { self?.listenerChanged(update, generation: generation) }
        }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            DispatchQueue.main.async { self?.registrationChanged(change, id: id, generation: generation) }
        }

        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: Self.domain),
            using: Self.localParameters()
        )
        browser.stateUpdateHandler = { [weak self] update in
            DispatchQueue.main.async { self?.browserChanged(update, generation: generation) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { self?.resultsChanged(results, generation: generation) }
        }

        self.listener = listener
        self.browser = browser
        if publicSyncEnabled {
            if let publicTransfer {
                publicTransfer.resume()
            } else {
                let transfer = NearbyPublicTransfer(references: references) { [weak self] entry, bytes in
                    guard let self, let text = String(data: bytes, encoding: .utf8),
                          !publicReferences.contains(where: { $0.id == entry.id }) else { return }
                    publicReferences.append(PublicReference(id: entry.id, title: entry.title, text: text))
                    publicReferences.sort { $0.id < $1.id }
                }
                transfer.activityDidChange = { [weak self] active in self?.activityDidChange?(active) }
                publicTransfer = transfer
            }
        }
        localID = id
        recentLocalIDs.append(id)
        if recentLocalIDs.count > 16 { recentLocalIDs.removeFirst() }
        state = .starting
        listener.start(queue: queue)
        browser.start(queue: queue)
        rotation = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(600)) }
            catch { return }
            guard let self, self.generation == generation else { return }
            self.rotate()
        }
    }

    func stop() {
        end(.idle)
    }

    func finishTransfersWithoutDiscovery() {
        guard let publicTransfer, publicTransfer.hasActiveTransfers else {
            stop()
            return
        }
        closeDiscovery()
        state = .idle
        publicTransfer.beginDraining()
    }

    func rotate() {
        if isRunning { stop() }
        start()
    }

    nonisolated static func peerID(from name: String, type: String, domain: String, excluding ownID: String? = nil) -> String? {
        guard type == serviceType || type == serviceType + ".",
              domain == Self.domain || domain == "local",
              name.hasPrefix(instancePrefix) else { return nil }
        let suffix = name.dropFirst(instancePrefix.count)
        guard suffix.utf8.count == 32,
              suffix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let id = String(suffix)
        return id == ownID ? nil : id
    }

    private static func localParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    private func listenerChanged(_ update: NWListener.State, generation: UUID) {
        guard generation == self.generation else { return }
        switch update {
        case .ready:
            mark(.listener, waitingFor: nil)
        case let .waiting(error):
            mark(.listener, waitingFor: Self.problem(for: error, terminal: false))
        case let .failed(error):
            end(Self.problem(for: error, terminal: true))
        case .cancelled:
            end(.idle)
        default:
            break
        }
    }

    private func browserChanged(_ update: NWBrowser.State, generation: UUID) {
        guard generation == self.generation else { return }
        switch update {
        case .ready:
            mark(.browser, waitingFor: nil)
        case let .waiting(error):
            peers.removeAll()
            publicTransfer?.updateTargets([:])
            mark(.browser, waitingFor: Self.problem(for: error, terminal: false))
        case let .failed(error):
            end(Self.problem(for: error, terminal: true))
        case .cancelled:
            end(.idle)
        default:
            break
        }
    }

    private func registrationChanged(_ change: NWListener.ServiceRegistrationChange, id: String, generation: UUID) {
        guard generation == self.generation else { return }
        switch change {
        case let .add(endpoint):
            guard Self.peerID(for: endpoint) == id else {
                end(.failed("Nearby could not register its identifier as advertised."))
                return
            }
            mark(.advertisement, waitingFor: nil)
        case let .remove(endpoint):
            if Self.peerID(for: endpoint) == id {
                mark(.advertisement, waitingFor: .waiting("Waiting for Nearby to advertise on the local network."))
            }
        @unknown default:
            break
        }
    }

    private func resultsChanged(_ results: Set<NWBrowser.Result>, generation: UUID) {
        guard generation == self.generation, waiting[.browser] == nil else { return }
        var endpoints: [String: NWEndpoint] = [:]
        for result in results {
            if let id = Self.peerID(for: result.endpoint), !recentLocalIDs.contains(id) {
                // A service seen on loopback is hosted on this device. Use that link instead of
                // resolving our own Wi-Fi address, which can stall even with a matching service.
                if let loopback = result.interfaces.first(where: { $0.type == .loopback }),
                   case let .service(name, type, domain, _) = result.endpoint {
                    endpoints[id] = .service(name: name, type: type, domain: domain, interface: loopback)
                } else if endpoints[id] == nil {
                    endpoints[id] = result.endpoint
                }
                if endpoints.count == Self.peerLimit { break }
            }
        }
        let updated = endpoints.keys.sorted().map(Peer.init(id:))
        if updated != peers { peers = updated }
        publicTransfer?.updateTargets(endpoints)
    }

    private static func peerID(for endpoint: NWEndpoint) -> String? {
        guard case let .service(name, type, domain, _) = endpoint else { return nil }
        return peerID(from: name, type: type, domain: domain)
    }

    private func mark(_ phase: Phase, waitingFor problem: State?) {
        waiting[phase] = problem
        if problem == nil { ready.insert(phase) }
        else { ready.remove(phase) }

        if waiting.values.contains(.permissionDenied) {
            state = .permissionDenied
        } else if let problem = waiting[.browser] ?? waiting[.listener] ?? waiting[.advertisement] {
            state = problem
        } else {
            state = ready == [.browser, .listener, .advertisement] ? .discovering : .starting
        }
    }

    private static func problem(for error: Error, terminal: Bool) -> State {
        // DNSServiceErr_PolicyDenied is the Bonjour signal for missing local-network access.
        if let error = error as? NWError, case let .dns(code) = error, code == -65570 {
            return .permissionDenied
        }
        if terminal { return .failed("Nearby stopped. \(error.localizedDescription)") }
        return .waiting("Waiting for a local network connection.")
    }

    private func end(_ nextState: State) {
        closeDiscovery()
        let transfer = publicTransfer
        publicTransfer = nil
        transfer?.stop()
        state = nextState
    }

    private func closeDiscovery() {
        generation = UUID()
        rotation?.cancel()
        rotation = nil
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
        ready.removeAll()
        waiting.removeAll()
        localID = nil
        peers.removeAll()
    }

    private enum Phase: Hashable { case listener, advertisement, browser }
}
