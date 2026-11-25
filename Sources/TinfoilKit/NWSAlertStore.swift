import Combine
import Foundation
import Network

@MainActor
final class NWSAlertStore: ObservableObject {
    @Published private(set) var area: String
    @Published private(set) var allowMetered: Bool
    @Published private(set) var snapshot: NWSAlertSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let cache: NWSAlertCache
    private let defaults: UserDefaults
    private let monitorQueue = DispatchQueue(label: "org.tinfoilkit.ios.nws-path")
    private var monitor: NWPathMonitor?
    private var monitorGeneration = UUID()
    private var path: Connection?
    private var periodicRefresh: Task<Void, Never>?
    private var activeRefresh: Task<Void, Never>?
    private var refreshID = UUID()
    private var lastAttempt: ContinuousClock.Instant?

    private struct Connection: Equatable, Sendable {
        let online: Bool
        let metered: Bool
    }

    init(defaults: UserDefaults = .standard,
         cache: NWSAlertCache = NWSAlertCache(directory: URL.applicationSupportDirectory.appendingPathComponent("NWSAlerts"))) {
        self.defaults = defaults
        self.cache = cache
        let saved = defaults.string(forKey: "nwsAlertArea") ?? ""
        area = NWSAlertSnapshot.endpoint(for: saved) == nil ? "" : saved
        allowMetered = defaults.bool(forKey: "nwsAlertAllowMetered")
        snapshot = cache.read(area: area)
    }

    func setArea(_ code: String) {
        guard code != area, code.isEmpty || NWSAlertSnapshot.endpoint(for: code) != nil else { return }
        resetRefresh()
        area = code
        defaults.set(code, forKey: "nwsAlertArea")
        snapshot = cache.read(area: code)
        errorMessage = nil
        Task { await refresh() }
    }

    func setAllowMetered(_ allowed: Bool) {
        guard allowed != allowMetered else { return }
        allowMetered = allowed
        defaults.set(allowed, forKey: "nwsAlertAllowMetered")
        if path?.metered == true { resetRefresh() }
        errorMessage = nil
        Task { await refresh() }
    }

    func setForeground(_ foreground: Bool) {
        if !foreground {
            monitor?.cancel()
            monitor = nil
            path = nil
            periodicRefresh?.cancel()
            periodicRefresh = nil
            cancelRefresh()
            return
        }
        guard monitor == nil else { return }
        let newMonitor = NWPathMonitor()
        let generation = UUID()
        monitor = newMonitor
        monitorGeneration = generation
        newMonitor.pathUpdateHandler = { [weak self] path in
            let connection = Connection(online: path.status == .satisfied,
                                        metered: path.isExpensive || path.isConstrained)
            Task { @MainActor [weak self] in
                guard let self, self.monitor != nil, self.monitorGeneration == generation else { return }
                let changed = self.path != connection
                self.path = connection
                if changed { await self.refresh() }
            }
        }
        newMonitor.start(queue: monitorQueue)
        periodicRefresh = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard !area.isEmpty, let path, path.online, allowMetered || !path.metered else { return }
        if let running = activeRefresh {
            await running.value
            return
        }
        let now = ContinuousClock.now
        if let lastAttempt, now - lastAttempt < .seconds(30) { return }
        lastAttempt = now
        isRefreshing = true
        errorMessage = nil
        let id = UUID()
        refreshID = id
        let requestedArea = area
        let previous = snapshot
        let metered = allowMetered
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if refreshID == id {
                    activeRefresh = nil
                    isRefreshing = false
                }
            }
            do {
                let next = try await Self.download(area: requestedArea, previous: previous, allowMetered: metered)
                try Task.checkCancellation()
                guard refreshID == id else { return }
                try cache.write(next)
                snapshot = next
            } catch is CancellationError {
            } catch {
                guard refreshID == id, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
        activeRefresh = task
        await task.value
    }

    private func resetRefresh() {
        cancelRefresh()
        lastAttempt = nil
    }

    private func cancelRefresh() {
        refreshID = UUID()
        activeRefresh?.cancel()
        activeRefresh = nil
        isRefreshing = false
    }

    nonisolated private static func download(
        area: String, previous: NWSAlertSnapshot?, allowMetered: Bool
    ) async throws -> NWSAlertSnapshot {
        guard let endpoint = NWSAlertSnapshot.endpoint(for: area) else { throw NWSAlertError.invalidResponse }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsCellularAccess = allowMetered
        configuration.allowsExpensiveNetworkAccess = allowMetered
        configuration.allowsConstrainedNetworkAccess = allowMetered
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        request.setValue("TinfoilKit-iOS (+https://github.com/scottleibrand/TinFoilKit-iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(previous?.etag, forHTTPHeaderField: "If-None-Match")
        request.setValue(previous?.lastModified, forHTTPHeaderField: "If-Modified-Since")

        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https",
              response.url?.host == endpoint.host else { throw NWSAlertError.invalidResponse }
        let etag = response.value(forHTTPHeaderField: "ETag")
        let lastModified = response.value(forHTTPHeaderField: "Last-Modified")
        if response.statusCode == 304, let previous {
            return previous.revalidated(at: .now, etag: etag, lastModified: lastModified)
        }
        guard response.statusCode == 200 else { throw NWSAlertError.httpStatus(response.statusCode) }
        let maximum = NWSAlertSnapshot.maximumResponseBytes
        guard response.expectedContentLength <= Int64(maximum) else { throw NWSAlertError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximum else { throw NWSAlertError.responseTooLarge }
            data.append(byte)
        }
        return try NWSAlertSnapshot.decode(data, area: area, checkedAt: .now, etag: etag, lastModified: lastModified)
    }
}
