import Combine
import Foundation
import Network

struct MapViewport: Equatable, Sendable {
    let west: Double
    let south: Double
    let east: Double
    let north: Double
    let zoom: Double

    func contains(latitude: Double, longitude: Double) -> Bool {
        guard latitude >= south, latitude <= north, longitude.isFinite else { return false }
        let span = east - west
        if abs(span) >= 360 { return true }
        let width = span < 0 ? span + 360 : span
        let delta = (longitude - west).truncatingRemainder(dividingBy: 360)
        return (delta < 0 ? delta + 360 : delta) <= width
    }

    var tiles: [MapTile] {
        guard [west, south, east, north, zoom].allSatisfy(\.isFinite), south <= north else { return [] }
        let current = Int(min(15, max(0, zoom)).rounded(.down))
        var levels = [current]
        if current > 0 { levels.append(current - 1) }
        if current < 15 { levels.append(current + 1) }
        return levels.flatMap { level -> [MapTile] in
            let dimension = 1 << level
            let width = east >= west ? min(east - west, 360) : (east - west).truncatingRemainder(dividingBy: 360) + 360
            let start = (west.truncatingRemainder(dividingBy: 360) + 540)
                .truncatingRemainder(dividingBy: 360)
            let left = Int(floor(start / 360 * Double(dimension)))
            let right = min(left + dimension - 1, Int(floor((start + width) / 360 * Double(dimension))))
            func row(_ latitude: Double) -> Int {
                let radians = min(85.05112878, max(-85.05112878, latitude)) * .pi / 180
                let scaled = (1 - asinh(tan(radians)) / .pi) / 2 * Double(dimension)
                return min(dimension - 1, max(0, Int(floor(scaled))))
            }
            let top = row(north)
            let bottom = row(south)
            guard (right - left + 1) * (bottom - top + 1) <= 64 else { return [] }
            return (left...right).flatMap { col in
                (top...bottom).map { MapTile(zoom: level, x: col % dimension, y: $0) }
            }
        }
    }
}

actor ExploredMapTiles {
    static let directory = URL.applicationSupportDirectory
        .appendingPathComponent("ExploredMapTiles-v1", isDirectory: true)
    static let shared = ExploredMapTiles(
        directory: directory,
        source: URL(string: "https://data.source.coop/protomaps/openstreetmap/v4.pmtiles?versionId=440HxKhBAVMB.cR3WUFToSUubTpDm6b7")!,
        expectedETag: #""9e09dd251e816c0ea9208e1e34c28eba-2572""#
    )

    let directory: URL
    private let source: PMTileArchive
    private let nonCellularSource: PMTileArchive
    private var prepared = false
    private var generation = 0

    init(directory: URL, source: URL, expectedETag: String? = nil) {
        self.directory = directory
        self.source = PMTileArchive(url: source, expectedETag: expectedETag)
        nonCellularSource = PMTileArchive(url: source, allowsCellular: false, expectedETag: expectedETag)
    }

    enum Outcome: Equatable, Sendable {
        case available, saved, missing
    }

    func save(_ tile: MapTile, seed: PMTileArchive?, download: Bool, allowsCellular: Bool = true) async -> Outcome {
        let generation = self.generation
        let file = directory
            .appendingPathComponent(String(tile.zoom), isDirectory: true)
            .appendingPathComponent(String(tile.x), isDirectory: true)
            .appendingPathComponent("\(tile.y).pbf")
        let files = FileManager.default
        if files.fileExists(atPath: file.path) { return .available }
        if let seed, (try? await seed.contains(tile)) == true { return .available }
        guard download, generation == self.generation, !Task.isCancelled else { return .missing }
        do {
            let archive = allowsCellular ? source : nonCellularSource
            let bytes = try await archive.vectorTile(tile) ?? Data()
            guard generation == self.generation, !Task.isCancelled else { return .missing }
            if !prepared {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                var folder = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try folder.setResourceValues(values)
                prepared = true
            }
            try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            return .saved
        } catch {
            return .missing
        }
    }

    func savedBytes() throws -> Int64 {
        let files = FileManager.default
        guard files.fileExists(atPath: directory.path) else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let entries = files.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else {
            throw CocoaError(.fileReadUnknown)
        }
        var total: Int64 = 0
        for case let file as URL in entries where file.pathExtension == "pbf" {
            try Task.checkCancellation()
            let info = try file.resourceValues(forKeys: keys)
            if info.isRegularFile == true { total += Int64(info.fileAllocatedSize ?? info.fileSize ?? 0) }
        }
        return total
    }

    func clearSavedTiles() throws {
        generation += 1
        prepared = false
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func cancelPendingDownloads() async {
        await source.cancelPendingReads()
        await nonCellularSource.cancelPendingReads()
    }
}

enum MapDownloadPolicy: String, CaseIterable, Identifiable {
    case off, wifiOnly, wifiAndCellular

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .wifiOnly: "Wi-Fi only"
        case .wifiAndCellular: "Wi-Fi and cellular"
        }
    }

    func permitsDownloads(online: Bool, wifi: Bool) -> Bool {
        online && (self == .wifiAndCellular || (self == .wifiOnly && wifi))
    }
}

@MainActor
final class MapExploration: ObservableObject {
    @Published private(set) var status: Status?
    @Published private(set) var revision = 0
    @Published private(set) var policy: MapDownloadPolicy

    enum Status: Equatable {
        case saving, saved, incomplete, unavailable
    }

    private let tiles = ExploredMapTiles.shared
    private let network = NWPathMonitor()
    private let defaults: UserDefaults
    private static let policyKey = "mapDownloadPolicy"
    private var online = false
    private var wifi = false
    private var visible = false
    private var current: Request?
    private var job: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    private var seed: PMTileArchive?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        policy = defaults.string(forKey: Self.policyKey).flatMap(MapDownloadPolicy.init(rawValue:)) ?? .wifiAndCellular
        network.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor in
                guard let self, self.online != online || self.wifi != wifi else { return }
                self.online = online
                self.wifi = wifi
                self.retry()
            }
        }
        network.start(queue: DispatchQueue(label: "org.tinfoilkit.ios.map-network"))
    }

    deinit {
        job?.cancel()
        refresh?.cancel()
        network.cancel()
    }

    func view(_ viewport: MapViewport, seedURL: URL?, styleID: UUID) {
        let request = Request(tiles: viewport.tiles, styleID: styleID)
        guard !request.tiles.isEmpty, request != current else { return }
        if current?.styleID != styleID { seed = seedURL.map { PMTileArchive(url: $0) } }
        current = request
        run(request)
    }

    func retry() {
        if let current { run(current) }
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if visible { retry() }
        else { stopDownloads() }
    }

    func setPolicy(_ preference: MapDownloadPolicy) {
        guard policy != preference else { return }
        policy = preference
        defaults.set(preference.rawValue, forKey: Self.policyKey)
        stopDownloads()
        retry()
    }

    func savedBytes() async throws -> Int64 { try await tiles.savedBytes() }

    func clearSavedTiles() async throws {
        setPolicy(.off)
        stopDownloads()
        defer { retry() }
        try await tiles.clearSavedTiles()
        refresh?.cancel()
        refresh = nil
        revision += 1
    }

    private func stopDownloads() {
        job?.cancel()
        Task { [tiles] in await tiles.cancelPendingDownloads() }
    }

    private func tileSaved() {
        // Coalesce nearby completions without waiting on the slowest download.
        guard refresh == nil else { return }
        refresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            self?.refresh = nil
            self?.revision += 1
        }
    }

    private func run(_ request: Request) {
        job?.cancel()
        guard visible else { return }
        let download = policy.permitsDownloads(online: online, wifi: wifi)
        let allowsCellular = policy == .wifiAndCellular
        status = download ? .saving : nil
        job = Task { [weak self, tiles, seed] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            var missing = false
            var mayDownload = download
            // Limit parallel requests while giving visible tiles priority over adjacent zoom levels.
            for start in stride(from: 0, to: request.tiles.count, by: 4) {
                guard !Task.isCancelled else { return }
                let end = min(request.tiles.count, start + 4)
                let fetchMissingTiles = mayDownload
                let outcomes = await withTaskGroup(of: ExploredMapTiles.Outcome.self, returning: [ExploredMapTiles.Outcome].self) { group in
                    for tile in request.tiles[start..<end] {
                        group.addTask {
                            await tiles.save(tile, seed: seed, download: fetchMissingTiles, allowsCellular: allowsCellular)
                        }
                    }
                    var outcomes: [ExploredMapTiles.Outcome] = []
                    for await outcome in group {
                        if outcome == .saved { self?.tileSaved() }
                        outcomes.append(outcome)
                    }
                    return outcomes
                }
                missing = missing || outcomes.contains(.missing)
                // A failed batch should not cause a separate network retry for every missing tile.
                if outcomes.allSatisfy({ $0 == .missing }) { mayDownload = false }
            }
            guard !Task.isCancelled else { return }
            self?.status = missing ? (download ? .incomplete : .unavailable) : .saved
        }
    }

    private struct Request: Equatable {
        let tiles: [MapTile]
        let styleID: UUID
    }
}
