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
    @Published private(set) var forecastLocation: NWSForecastLocation?
    @Published private(set) var forecastTimeZone: TimeZone = .current
    @Published private(set) var forecasts: [NWSForecastKind: NWSForecastSnapshot] = [:]
    @Published private(set) var forecastIsRefreshing = false
    @Published private(set) var forecastErrorMessage: String?

    private let cache: NWSAlertCache
    private let defaults: UserDefaults
    private let monitorQueue = DispatchQueue(label: "org.tinfoilkit.ios.nws-path")
    private var monitor: NWPathMonitor?
    private var monitorGeneration = UUID()
    private var path: RegionalUpdateConnection?
    private var periodicRefresh: Task<Void, Never>?
    private var activeRefresh: Task<Void, Never>?
    private var refreshID = UUID()
    private var alertsThrottle = RegionalRefreshThrottle()
    private var forecastTask: Task<Void, Never>?
    private var forecastID = UUID()
    private var forecastThrottle = RegionalRefreshThrottle()

    init(defaults: UserDefaults = .standard,
         cache: NWSAlertCache = NWSAlertCache(directory: URL.applicationSupportDirectory.appendingPathComponent("NWSAlerts"))) {
        self.defaults = defaults
        self.cache = cache
        let saved = defaults.string(forKey: "nwsAlertArea") ?? ""
        let area = NWSAlertSnapshot.endpoint(for: saved) == nil ? "" : saved
        self.area = area
        allowMetered = defaults.bool(forKey: "nwsAlertAllowMetered")
        snapshot = cache.read(area: area)
        forecastLocation = defaults.string(forKey: "nwsForecastCoordinates").flatMap(NWSForecastLocation.init)
        loadForecasts()
    }

    func setArea(_ code: String) {
        guard code != area, code.isEmpty || NWSAlertSnapshot.endpoint(for: code) != nil else { return }
        cancelAlertRefresh()
        alertsThrottle = RegionalRefreshThrottle()
        area = code
        defaults.set(code, forKey: "nwsAlertArea")
        snapshot = cache.read(area: code)
        errorMessage = nil
        Task { await refresh() }
    }

    func setForecastLocation(_ next: NWSForecastLocation?) {
        guard next != forecastLocation else { return }
        let previous = forecastCache
        cancelForecastRefresh()
        forecastThrottle = RegionalRefreshThrottle()
        forecastLocation = next
        defaults.set(next?.coordinates, forKey: "nwsForecastCoordinates")
        forecastErrorMessage = nil
        if let previous { try? FileManager.default.removeItem(at: previous.directory) }
        loadForecasts()
        if next != nil { Task { await refresh() } }
    }

    func setAllowMetered(_ allowed: Bool) {
        guard allowed != allowMetered else { return }
        allowMetered = allowed
        defaults.set(allowed, forKey: "nwsAlertAllowMetered")
        if !mayRefresh { pauseForConnectionLoss() }
        errorMessage = nil
        forecastErrorMessage = nil
        Task { await refresh() }
    }

    func setForeground(_ foreground: Bool) {
        if !foreground {
            monitor?.cancel()
            monitor = nil
            path = nil
            periodicRefresh?.cancel()
            periodicRefresh = nil
            pauseForConnectionLoss()
            return
        }
        guard monitor == nil else { return }
        let newMonitor = NWPathMonitor()
        let generation = UUID()
        monitor = newMonitor
        monitorGeneration = generation
        newMonitor.pathUpdateHandler = { [weak self] path in
            let connection = RegionalUpdateConnection(online: path.status == .satisfied,
                                                      metered: path.isExpensive || path.isConstrained)
            Task { @MainActor [weak self] in
                guard let self, self.monitor != nil, self.monitorGeneration == generation,
                      self.path != connection else { return }
                self.path = connection
                if self.mayRefresh {
                    await self.refresh()
                } else {
                    self.pauseForConnectionLoss()
                }
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
        let selectedArea = area
        await refreshAlerts()
        guard selectedArea == area else { return }
        await updateForecasts(force: false)
    }

    func refreshAlerts() async {
        guard !area.isEmpty, mayRefresh else { return }
        if let running = activeRefresh {
            await running.value
            return
        }
        guard alertsThrottle.begin(after: .seconds(30)) else { return }
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
                alertsThrottle.finishSuccessfully()
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
        cancelAlertRefresh()
        cancelForecastRefresh()
        alertsThrottle.connectionInterrupted()
        forecastThrottle.connectionInterrupted()
    }

    private func cancelAlertRefresh() {
        refreshID = UUID()
        activeRefresh?.cancel()
        activeRefresh = nil
        isRefreshing = false
    }

    private func cancelForecastRefresh() {
        forecastID = UUID()
        forecastTask?.cancel()
        forecastTask = nil
        forecastIsRefreshing = false
    }

    func refreshForecasts() async {
        await updateForecasts(force: true)
    }

    private var forecastCache: NWSForecastCache? {
        forecastLocation.map { location in
            NWSForecastCache(directory: cache.directory.appendingPathComponent("Forecast", isDirectory: true)
                .appendingPathComponent(location.coordinates, isDirectory: true))
        }
    }

    private func loadForecasts() {
        forecasts = [:]
        forecastTimeZone = .current
        guard let forecastCache else { return }
        if let id = forecastCache.readPoint()?.timeZoneIdentifier, let timeZone = TimeZone(identifier: id) {
            forecastTimeZone = timeZone
        }
        for kind in NWSForecastKind.allCases {
            forecasts[kind] = forecastCache.read(kind)?.snapshot
        }
    }

    private func updateForecasts(force: Bool) async {
        guard !Task.isCancelled, mayRefresh, let location = forecastLocation, let forecastCache else { return }
        if let forecastTask {
            await forecastTask.value
            return
        }
        let kinds = NWSForecastKind.allCases.filter { kind in
            force || (forecasts[kind].map { Date.now.timeIntervalSince($0.checkedAt) >= 3 * 60 * 60 } ?? true)
        }
        guard !kinds.isEmpty else { return }
        guard forecastThrottle.begin(after: .seconds(60)) else { return }
        let metered = allowMetered
        let id = UUID()
        forecastID = id
        forecastIsRefreshing = true
        forecastErrorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if forecastID == id {
                    forecastTask = nil
                    forecastIsRefreshing = false
                }
            }
            do {
                let point = try await Self.forecastPoint(location: location, cache: forecastCache, allowMetered: metered)
                try Task.checkCancellation()
                guard forecastID == id else { return }
                if forecastCache.readPoint() != point { try forecastCache.writePoint(point) }
                forecastTimeZone = point.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
                var errors: [String] = []
                for kind in kinds {
                    try Task.checkCancellation()
                    do {
                        let endpoint = point.url(for: kind)
                        let previous = forecastCache.read(kind)
                        let next = try await Self.downloadForecast(
                            kind: kind, endpoint: endpoint,
                            previous: previous?.endpoint == endpoint ? previous?.snapshot : nil, allowMetered: metered
                        )
                        try Task.checkCancellation()
                        guard forecastID == id else { return }
                        try forecastCache.write(.init(endpoint: endpoint, snapshot: next))
                        forecasts[kind] = next
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let description = kind == .daily ? "Day and night forecast" : "Hourly forecast"
                        errors.append("\(description) could not refresh. \(error.localizedDescription)")
                    }
                }
                guard forecastID == id, !Task.isCancelled else { return }
                forecastErrorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
                if errors.isEmpty { forecastThrottle.finishSuccessfully() }
            } catch is CancellationError {
            } catch {
                guard forecastID == id, !Task.isCancelled else { return }
                forecastErrorMessage = error.localizedDescription
            }
        }
        forecastTask = task
        await task.value
    }

    nonisolated private static func forecastPoint(location: NWSForecastLocation, cache: NWSForecastCache,
                                                  allowMetered: Bool) async throws -> NWSForecastPoint {
        let saved = cache.readPoint()
        if let saved, Date.now.timeIntervalSince(saved.fetchedAt) < 7 * 24 * 60 * 60 { return saved }
        do {
            let response = try await NWSHTTPClient.fetch(
                location.endpoint, maximumBytes: NWSForecastPoint.maxResponseBytes, allowMetered: allowMetered
            )
            guard let data = response.body else { throw NWSHTTPClient.ResponseError.invalid }
            return try NWSForecastPoint.decode(data, fetchedAt: response.checkedAt)
        } catch {
            try Task.checkCancellation()
            if let saved { return saved }
            throw error
        }
    }

    nonisolated private static func downloadForecast(
        kind: NWSForecastKind, endpoint: URL, previous: NWSForecastSnapshot?, allowMetered: Bool
    ) async throws -> NWSForecastSnapshot {
        let response = try await NWSHTTPClient.fetch(
            endpoint, maximumBytes: NWSForecastSnapshot.maxResponseBytes, allowMetered: allowMetered,
            etag: previous?.etag, lastModified: previous?.lastModified
        )
        if let data = response.body {
            return try NWSForecastSnapshot.decode(data, kind: kind, checkedAt: response.checkedAt,
                                                  expiresAt: response.expiresAt, etag: response.etag,
                                                  lastModified: response.lastModified)
        }
        guard let previous else { throw NWSHTTPClient.ResponseError.invalid }
        return previous.revalidated(at: response.checkedAt, expiresAt: response.expiresAt,
                                    etag: response.etag, lastModified: response.lastModified)
    }

    nonisolated private static func download(
        area: String, previous: NWSAlertSnapshot?, allowMetered: Bool
    ) async throws -> NWSAlertSnapshot {
        guard let endpoint = NWSAlertSnapshot.endpoint(for: area) else { throw NWSAlertError.invalidResponse }
        let response = try await NWSHTTPClient.fetch(
            endpoint, maximumBytes: NWSAlertSnapshot.maximumResponseBytes, allowMetered: allowMetered,
            etag: previous?.etag, lastModified: previous?.lastModified
        )
        if let data = response.body {
            return try NWSAlertSnapshot.decode(data, area: area, checkedAt: response.checkedAt,
                                               etag: response.etag, lastModified: response.lastModified)
        }
        guard let previous else { throw NWSHTTPClient.ResponseError.invalid }
        return previous.revalidated(at: response.checkedAt, etag: response.etag, lastModified: response.lastModified)
    }
}
