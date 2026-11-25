import Combine
import Foundation
import Network

@MainActor
final class WSDOTClosureStore: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var allowMetered: Bool
    @Published private(set) var snapshot: WSDOTClosureSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let file: URL
    private let queue = DispatchQueue(label: "org.tinfoilkit.ios.wsdot-path")
    private var isForeground = false
    private var monitor: NWPathMonitor?
    private var path: RegionalUpdateConnection?
    private var monitorID = UUID()
    private var refreshID = UUID()
    private var activeRefresh: Task<Void, Never>?
    private var periodicRefresh: Task<Void, Never>?
    private var throttle = RegionalRefreshThrottle()

    init(defaults: UserDefaults = .standard,
         directory: URL = URL.applicationSupportDirectory.appendingPathComponent("RoadClosures")) {
        self.defaults = defaults
        let file = directory.appendingPathComponent("wsdot-puget-sound-v1.json")
        let enabled = defaults.bool(forKey: "wsdotClosureAdvisories")
        self.file = file
        self.enabled = enabled
        allowMetered = defaults.bool(forKey: "wsdotClosureAllowMetered")
        snapshot = enabled ? Self.read(file) : nil
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        defaults.set(enabled, forKey: "wsdotClosureAdvisories")
        snapshot = enabled ? Self.read(file) : nil
        errorMessage = nil
        updateMonitoring()
    }

    func setAllowMetered(_ allowed: Bool) {
        guard allowed != allowMetered else { return }
        allowMetered = allowed
        defaults.set(allowed, forKey: "wsdotClosureAllowMetered")
        if !mayRefresh { pauseForConnectionLoss() }
        errorMessage = nil
        Task { await refresh() }
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        updateMonitoring()
    }

    private func updateMonitoring() {
        guard enabled, isForeground else {
            monitor?.cancel()
            monitor = nil
            path = nil
            periodicRefresh?.cancel()
            periodicRefresh = nil
            pauseForConnectionLoss()
            return
        }
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        let id = UUID()
        self.monitor = monitor
        monitorID = id
        monitor.pathUpdateHandler = { [weak self] path in
            let connection = RegionalUpdateConnection(online: path.status == .satisfied,
                                                      metered: path.isExpensive || path.isConstrained)
            Task { @MainActor [weak self] in
                guard let self, self.monitor != nil, self.monitorID == id, self.path != connection else { return }
                self.path = connection
                if self.mayRefresh {
                    await self.refresh()
                } else {
                    self.pauseForConnectionLoss()
                }
            }
        }
        monitor.start(queue: queue)
        periodicRefresh = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(600)) } catch { return }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard enabled, isForeground, mayRefresh else { return }
        if let activeRefresh {
            await activeRefresh.value
            return
        }
        guard throttle.begin(after: .seconds(60)) else { return }
        let id = UUID()
        refreshID = id
        isRefreshing = true
        errorMessage = nil
        let metered = allowMetered
        let previous = snapshot
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if refreshID == id {
                    activeRefresh = nil
                    isRefreshing = false
                }
            }
            do {
                let next = try await Self.download(previous: previous, allowMetered: metered)
                try Task.checkCancellation()
                guard refreshID == id else { return }
                try Self.write(next, to: file)
                snapshot = next
                throttle.finishSuccessfully()
            } catch is CancellationError {
            } catch {
                guard refreshID == id, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
        activeRefresh = task
        await task.value
    }

    private var mayRefresh: Bool {
        path?.allowsRefresh(allowMetered: allowMetered) == true
    }

    private func pauseForConnectionLoss() {
        refreshID = UUID()
        activeRefresh?.cancel()
        activeRefresh = nil
        isRefreshing = false
        throttle.connectionInterrupted()
    }

    nonisolated private static func read(_ file: URL) -> WSDOTClosureSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WSDOTClosureSnapshot.self, from: data)
    }

    nonisolated private static func write(_ snapshot: WSDOTClosureSnapshot, to file: URL) throws {
        var directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }

    nonisolated private static func download(
        previous: WSDOTClosureSnapshot?, allowMetered: Bool
    ) async throws -> WSDOTClosureSnapshot {
        let url = WSDOTClosureSnapshot.endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsCellularAccess = allowMetered
        configuration.allowsExpensiveNetworkAccess = allowMetered
        configuration.allowsConstrainedNetworkAccess = allowMetered
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/geo+json, application/json", forHTTPHeaderField: "Accept")
        request.setValue(previous?.etag, forHTTPHeaderField: "If-None-Match")
        request.setValue(previous?.lastModified, forHTTPHeaderField: "If-Modified-Since")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https",
              response.url?.host == url.host else { throw FeedError.invalidResponse }
        let etag = response.value(forHTTPHeaderField: "ETag")
        let lastModified = response.value(forHTTPHeaderField: "Last-Modified")
        if response.statusCode == 304, let previous {
            return previous.revalidated(at: .now, etag: etag, lastModified: lastModified)
        }
        guard response.statusCode == 200 else { throw FeedError.httpStatus(response.statusCode) }
        let limit = WSDOTClosureSnapshot.maximumResponseBytes
        guard response.expectedContentLength <= Int64(limit) else { throw FeedError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw FeedError.tooLarge }
            data.append(byte)
        }
        return try WSDOTClosureSnapshot.decode(data, checkedAt: .now, etag: etag, lastModified: lastModified)
    }

    private enum FeedError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "WSDOT returned an unexpected response."
            case let .httpStatus(code): "WSDOT returned HTTP \(code)."
            case .tooLarge: "WSDOT’s closure list exceeded the download limit."
            }
        }
    }
}
