import SwiftUI
import ZIMArchive

struct OfflineReadinessView: View {
    @ObservedObject var indexing: LibraryIndexing
    @ObservedObject var household: HouseholdStore
    @AppStorage("askUsesOnDeviceModel") private var useModel = true
    @State private var availableBytes: Int64?
    @State private var map: Result<OfflineMap?, Error>?
    @State private var places: Result<[RegionalPlaceStorage.Installed]?, Error>?
    @State private var routing: Result<[RegionalRouteStore.Installed]?, Error>?
    @State private var bundles: Result<[RegionalBundleStorage.Installed]?, Error>?

    var body: some View {
        List {
            Section {
                NavigationLink("Run offline checks", destination: OfflineFunctionalChecksView(indexing: indexing))
            } footer: {
                Text("Open installed content, search locally, and calculate a route. To rehearse a disconnect, turn on Airplane Mode and turn Wi-Fi off first.")
            }
            Section("Storage") {
                LabeledContent("Available", value: availableBytes?.formatted(.byteCount(style: .file)) ?? "Unknown")
                LabeledContent("Installed archives", value: indexing.archives.reduce(Int64(0)) {
                    $0 + $1.byteCount
                }.formatted(.byteCount(style: .file)))
            }
            homeCoverageSection
            librarySection
            mapSection
            regionalBundlesSection
            Section("Before you go offline") {
                NavigationLink("Offline setup and troubleshooting", destination: OfflineHelpView())
            }
        }
        .navigationTitle("Offline readiness")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private var librarySection: some View {
        Section("Library") {
            if let error = indexing.refreshError {
                Text(error).foregroundStyle(.secondary)
            } else if indexing.archives.isEmpty {
                Text("No archives installed. Open Content Packs in Library to download a pack.")
                    .foregroundStyle(.secondary)
            }
            ForEach(indexing.archives) { archive in
                VStack(alignment: .leading, spacing: 4) {
                    Text(archive.title)
                        .font(.headline)
                    Text(archive.byteCount.formatted(.byteCount(style: .file)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    archiveStatus(archive)
                    if let pack = archive.pack {
                        Text("Edition \(pack.version)")
                        Text(pack.attribution)
                        Link("Publisher download", destination: pack.source)
                    }
                }
                .font(.subheadline)
                .padding(.vertical, 2)
            }
            if !indexing.errors.isEmpty {
                Button("Retry failed indexes") { indexing.retryFailedIndexes() }
            }
            LabeledContent("On-device answers", value: modelStatus)
        }
    }

    private var modelStatus: String {
        guard LibraryAnswer.isAvailable else { return "Unavailable" }
        return useModel ? "Available" : "Turned off in Ask"
    }

    @ViewBuilder
    private func archiveStatus(_ archive: InstalledArchive) -> some View {
        if let error = indexing.errors[archive.id] {
            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
        } else if let progress = indexing.progress, progress.id == archive.id {
            ProgressView(value: progress.fraction) {
                Text("Indexing · \(progress.fraction.formatted(.percent.precision(.fractionLength(0))))")
            }
        } else if indexing.searchable.contains(archive.id) {
            Label("Search index ready", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        } else {
            Text("Waiting to index").foregroundStyle(.secondary)
        }
    }

    private var homeCoverageSection: some View {
        Section {
            if let home = household.snapshot.home {
                let point = MapRoute.Point(latitude: home.latitude, longitude: home.longitude)
                LabeledContent("Active basemap", value: homeCoverage(map, missing: "No active basemap") {
                    [$0.contains(home.coordinate)]
                })
                LabeledContent("Regional places", value: homeCoverage(places, missing: "No regional place data") {
                    $0.map { $0.metadata.bounds?.contains(home.coordinate) }
                })
                LabeledContent("Offline routing", value: homeCoverage(routing, missing: "No regional routing pack") {
                    $0.map { $0.pack.bounds.contains(point) }
                })
            } else {
                Text("Set Home in Map to check coverage for that location.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Coverage at Home")
        } footer: {
            if household.snapshot.home != nil {
                Text("These checks use installed coverage bounds. Offline routes also need coverage at the destination.")
            }
        }
    }

    private var regionalBundlesSection: some View {
        Section("Regional bundles") {
            switch bundles {
            case let .success(installed?):
                ForEach(installed) { bundle in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bundle.manifest.region).font(.headline)
                        Text("Edition \(bundle.manifest.dataVersion)").font(.subheadline)
                        if bundle.isUsable {
                            Text(bundle.manifest.assets.basemap == nil ? "Places and routing ready" :
                                    "Basemap, places and routing ready")
                        } else {
                            Text("Missing or damaged files. Reinstall this bundle from Map.")
                        }
                    }
                }
            case .success(nil): Text("No regional bundles installed")
            case let .failure(error): Text(error.localizedDescription)
            case nil: Text("Checking installed bundles…")
            }
        }
    }

    private func homeCoverage<Value>(
        _ state: Result<Value?, Error>?, missing: String, candidates: (Value) -> [Bool?]
    ) -> String {
        switch state {
        case let .success(value?): OfflineCoverageStatus(candidates: candidates(value)).title
        case .success(nil): missing
        case .failure: "Could not check"
        case nil: "Checking…"
        }
    }

    private var mapSection: some View {
        Section("Maps") {
            coverageRow("Basemap", state: map, missing: "No basemap installed") { active in
                Text(active.title)
                coverageBounds(west: active.minLongitude, south: active.minLatitude,
                               east: active.maxLongitude, north: active.maxLatitude)
                Text("Maximum archive zoom \(active.maxZoom)")
                Link("OpenStreetMap attribution", destination: Self.osmAttribution)
                Text("Map may also contain areas saved as you browse.")
            }
            coverageRow("Address and service search", state: places, missing: placeSearchStatus) { indexes in
                ForEach(indexes) { placeIndex in
                    let metadata = placeIndex.metadata
                    Text(metadata.region)
                    Text("\(metadata.placeCount.formatted()) mapped places")
                    if let version = metadata.dataVersion { Text("Data edition \(version)") }
                    if let bounds = metadata.bounds {
                        coverageBounds(west: bounds.west, south: bounds.south, east: bounds.east, north: bounds.north)
                    }
                    Link("Data source", destination: metadata.source)
                    Link("\(metadata.attribution) · \(metadata.license)", destination: metadata.licenseURL)
                }
            }
            coverageRow("Walking and driving", state: routing, missing: routingStatus) { packs in
                ForEach(packs) { installed in
                    let pack = installed.pack
                    Text(pack.region)
                    Text("Data edition \(pack.dataVersion)")
                    let bounds = pack.bounds
                    coverageBounds(west: bounds.west, south: bounds.south, east: bounds.east, north: bounds.north)
                    Link("Data source", destination: pack.source)
                    Link("\(pack.attribution) · \(pack.license)", destination: pack.licenseURL)
                }
            }
        }
    }

    private var placeSearchStatus: String {
        if hasSeattleAsset("seattle-places") { return "Seattle place search is available" }
        return "No regional place pack installed"
    }

    private var routingStatus: String {
        if hasSeattleAsset("seattle-walking") { return "Seattle walking previews are available" }
        return "No routing pack installed"
    }

    private func hasSeattleAsset(_ name: String) -> Bool {
        guard case let .success(active?)? = map, active.archive.lastPathComponent == "seattle.pmtiles" else {
            return false
        }
        return Bundle.main.url(forResource: name, withExtension: "sqlite", subdirectory: "map-assets") != nil
    }

    private func coverageRow<Value, Detail: View>(
        _ title: String, state: Result<Value?, Error>?, missing: String, @ViewBuilder detail: (Value) -> Detail
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Group {
                switch state {
                case let .success(value?): detail(value)
                case .success(nil): Text(missing)
                case let .failure(error): Text(error.localizedDescription)
                case nil: Text("Checking installed data…")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func coverageBounds(west: Double, south: Double, east: Double, north: Double) -> some View {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
        return Text("Bounds · \(south.formatted(format))…\(north.formatted(format)) lat, \(west.formatted(format))…\(east.formatted(format)) lon")
    }

    @MainActor
    private func refresh() async {
        let url = URL.temporaryDirectory
        availableBytes = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        do { map = .success(try await MapStorage().current()) }
        catch { map = .failure(error) }
        do {
            let indexes = try await RegionalPlaceStorage().installedIndexes()
            places = .success(indexes.isEmpty ? nil : indexes)
        }
        catch { places = .failure(error) }
        do {
            let packs = try await RegionalRouteStore().installedPacks()
            routing = .success(packs.isEmpty ? nil : packs)
        }
        catch { routing = .failure(error) }
        do {
            let installed = try await RegionalBundleStorage().installedBundles()
            bundles = .success(installed.isEmpty ? nil : installed)
        }
        catch { bundles = .failure(error) }
        await indexing.refresh()
    }

    private static let osmAttribution = URL(string: "https://www.openstreetmap.org/copyright")!
}

private struct OfflineHelpView: View {
    var body: some View {
        List {
            Section("Prepare your library") {
                Text("In Library, open Content Packs to download what you need. You can also import a ZIM archive from Files.")
                Text("Open an installed archive at any time. Ask searches articles as indexing progresses and opens matching PDFs at the cited page.")
            }
            Section("Prepare your map") {
                Text("Open Map while connected and browse the areas and zoom levels you expect to use. Wait until the map reports the area is available offline.")
                Text("Use the plus menu in Map to import a regional bundle or add its map, places, and routing files separately. Regional place data enables address and nearby service search. Routing requires a graph that covers both endpoints.")
            }
            Section("Verify on this phone") {
                Text("Turn on Airplane Mode and turn Wi-Fi off. Reopen Tinfoil Kit, open a saved article, try Search, and check the areas you plan to use in Map.")
                Text("Use Household to save notes, home, and pins. Print the essentials can preview a household sheet and selected pages from installed guides.")
                Text("Household sharing works over a local network while the host keeps the sharing screen open.")
            }
            Section("Recover a missing item") {
                Text("If a pack download failed, reopen Content Packs and retry it while connected. For an index failure, use Retry failed indexes in Offline readiness.")
                Text("If the map is blank offline, return to a confirmed saved area or reconnect and let the missing tiles download.")
            }
        }
        .navigationTitle("Offline help")
        .navigationBarTitleDisplayMode(.inline)
    }
}
