import CoreLocation
import MapLibre
import SwiftUI
import UniformTypeIdentifiers

struct OfflineMapView: View {
    @ObservedObject var household: HouseholdStore
    @State private var storage = MapStorage()
    @State private var regionStorage = RegionalPlaceStorage()
    @State private var placeRegions: [RegionalPlaceStorage.Installed] = []
    @State private var routeStorage = RegionalRouteStore()
    @State private var routingRegions: [RegionalRouteStore.Installed] = []
    @StateObject private var location = MapLocation()
    @StateObject private var exploration = MapExploration()
    @AppStorage("lastOfflineMapPosition") private var savedPosition = ""
    @State private var map: OfflineMap?
    @State private var style: OfflineMapStyle?
    @State private var choosing = false
    @State private var importKind = MapImportKind.tiles
    @State private var searchingPlaces = false
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var marker: MapMarker?
    @State private var viewport: MapViewport?
    @State private var selectedPlace: MapPlace?
    @State private var routeOrigin: MapPlace?
    @State private var routeMode = MapTravelMode.walking
    @State private var route: DisplayedRoute?
    @State private var routeRequest: RouteRequest?
    @State private var showingSteps = false
    @State private var importingRouting = false
    @State private var pointActions: HouseholdPlace?
    @State private var editingPin: HouseholdPlace?
    @State private var showingBasemaps = false
    @State private var showingPlaceRegions = false
    @State private var showingRoutingPacks = false

    private var savedPlaces: [HouseholdPlace] {
        (household.snapshot.home.map { [$0] } ?? []) + household.snapshot.pins
    }

    private var bundledRoutingPacks: [URL] {
        (Bundle.main.urls(forResourcesWithExtension: "tfkroute", subdirectory: "routing-packs") ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private var locationIsOffscreen: Bool {
        guard let viewport, let coordinate = location.fix?.coordinate else { return false }
        return !viewport.contains(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private var locationButtonTitle: String {
        if locationIsOffscreen { return "Return to my location" }
        return location.following ? "Stop following" : "Find my location"
    }

    private var placeIndex: URL? {
        guard map?.archive.lastPathComponent == "seattle.pmtiles" else { return nil }
        return Bundle.main.url(forResource: "seattle-places", withExtension: "sqlite", subdirectory: "map-assets")
    }

    private var walkingIndex: URL? {
        guard map?.archive.lastPathComponent == "seattle.pmtiles" else { return nil }
        return Bundle.main.url(forResource: "seattle-walking", withExtension: "sqlite", subdirectory: "map-assets")
    }

    var body: some View {
        NavigationStack {
            mapContent
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { mapToolbar }
            .confirmationDialog(
                pointActions?.coordinateText ?? "Map location",
                isPresented: Binding(get: { pointActions != nil }, set: { if !$0 { pointActions = nil } }),
                titleVisibility: .visible,
                presenting: pointActions
            ) { place in
                Button("Pin this place") { editingPin = place }
                Button("Set as home") {
                    let home = HouseholdPlace(name: "Home", latitude: place.latitude, longitude: place.longitude)
                    do { try household.setHome(home) }
                    catch { errorMessage = error.localizedDescription }
                }
                Button("Copy decimal coordinates") { UIPasteboard.general.string = place.coordinateText }
                Button("Copy degrees, minutes and seconds") {
                    UIPasteboard.general.string = MapCoordinateText.degreesMinutesSeconds(place.coordinate)
                }
                if let origin = location.fix?.coordinate ?? household.snapshot.home?.coordinate {
                    if supportsOfflineRoute(from: origin, to: place.coordinate) {
                        Button("Drive here") { routeHere(place, from: origin, mode: .driving) }
                    }
                    if supportsOfflineRoute(from: origin, to: place.coordinate) || walkingIndex != nil {
                        Button("Walk here") { routeHere(place, from: origin, mode: .walking) }
                    }
                }
            } message: { place in
                Text(MapCoordinateText.degreesMinutesSeconds(place.coordinate))
            }
            .sheet(item: $editingPin) { place in
                HouseholdPinEditor(place: place, onSave: household.savePin)
            }
            .sheet(isPresented: $searchingPlaces, onDismiss: { routeOrigin = nil }) {
                placeSearch
            }
            .sheet(isPresented: $showingSteps) {
                if let route { steps(for: route) }
            }
            .sheet(isPresented: $showingBasemaps) {
                InstalledBasemapsView(storage: storage, activeMapID: map?.id) { selected in
                    savedPosition = ""
                    setMap(selected)
                }
            }
            .sheet(isPresented: $showingPlaceRegions) {
                InstalledPlaceDataView(storage: regionStorage, regions: $placeRegions)
            }
            .sheet(isPresented: $showingRoutingPacks) {
                InstalledRoutingPacksView(storage: routeStorage, packs: $routingRegions)
            }
            .onChange(of: location.fix?.timestamp) {
                if let fix = location.fix {
                    marker = MapMarker(coordinate: fix.coordinate, title: "Current position")
                }
            }
            .onAppear { location.setVisible(true, centerInitially: savedPosition.isEmpty) }
            .onDisappear { location.setVisible(false) }
            .fileImporter(
                isPresented: $choosing,
                allowedContentTypes: importKind.contentTypes
            ) { result in
                let kind = importKind
                Task { await install(result, kind: kind) }
            }
            .alert("Map error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                defer { loading = false }
                guard style == nil else { return }
                do {
                    setMap(try await storage.current())
                    placeRegions = try await regionStorage.installedIndexes()
                }
                catch { errorMessage = error.localizedDescription }
                do { routingRegions = try await routeStorage.installedPacks() }
                catch { errorMessage = error.localizedDescription }
            }
            .task(id: routeRequest?.id) {
                if let routeRequest { await calculate(routeRequest) }
            }
        }
    }

    @ViewBuilder
    private var mapContent: some View {
        Group {
            if let style {
                MapSurface(
                    style: style,
                    initialPosition: MapPosition(savedPosition) ?? MapPosition(
                        coordinate: map?.center ?? CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321),
                        zoom: 11
                    ),
                    marker: marker,
                    route: route,
                    savedPlaces: savedPlaces,
                    tileRevision: exploration.revision,
                    onViewport: { viewport, position in
                        if self.viewport != viewport { self.viewport = viewport }
                        if savedPosition != position.encoded { savedPosition = position.encoded }
                        exploration.view(viewport, seedURL: style.seed?.archive, styleID: style.id)
                    },
                    onHold: { coordinate in
                        pointActions = HouseholdPlace(name: "Dropped pin", latitude: coordinate.latitude,
                                                      longitude: coordinate.longitude)
                    },
                    onError: { errorMessage = $0.localizedDescription }
                )
                .id(style.id)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        if let message = location.message {
                            Text(message)
                        }
                        Text(mapTitle)
                            .font(.footnote.weight(.semibold))
                        if !placeRegions.isEmpty {
                            Button("Installed place data") { showingPlaceRegions = true }
                                .font(.caption)
                        }
                        Group {
                            switch exploration.status {
                            case .saving:
                                ProgressView("Saving this area").controlSize(.small)
                            case .saved:
                                Text("Available offline")
                            case .incomplete:
                                Button("Retry saving this area") { exploration.retry() }
                            case nil:
                                Color.clear
                            }
                        }
                        .font(.caption)
                        .frame(height: 20)
                        if importingRouting {
                            ProgressView("Installing routing pack")
                        }
                        if let routeRequest {
                            ProgressView("Finding \(routeRequest.mode.title.lowercased()) route")
                        } else if let route {
                            Text(route.summary)
                            if !route.route.steps.isEmpty {
                                Button("Route steps") { showingSteps = true }
                            }
                            Button(route.mode == .walking ? "Clear walking route" : "Clear driving route") {
                                self.route = nil
                            }
                        } else if let selectedPlace {
                            Text(selectedPlace.name)
                            if supportsOfflineRoute(from: selectedPlace.coordinate) || walkingIndex != nil {
                                Button("Start walk here") { findDestination(from: selectedPlace, mode: .walking) }
                            }
                            if supportsOfflineRoute(from: selectedPlace.coordinate) {
                                Button("Start drive here") { findDestination(from: selectedPlace, mode: .driving) }
                            }
                        }
                        Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                            .font(.caption)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                }
            } else if loading {
                ProgressView("Opening map")
            } else {
                ContentUnavailableView {
                    Label("No map installed", systemImage: "map")
                } description: {
                    Text("Import a Protomaps PMTiles vector archive to use it offline.")
                } actions: {
                    Button("Import map") { chooseImport(.tiles) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var mapToolbar: some ToolbarContent {
        if style != nil {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Search places", systemImage: "magnifyingglass") { searchingPlaces = true }
                Button(
                    locationButtonTitle,
                    systemImage: location.following ? "location.fill" : "location"
                ) { handleLocationButton() }
                Menu {
                    Button("Installed basemaps", systemImage: "map") { showingBasemaps = true }
                    Button("Installed place data", systemImage: "list.bullet") { showingPlaceRegions = true }
                    Button("Import map tiles", systemImage: "map") { chooseImport(.tiles) }
                    Button("Import regional place data", systemImage: "magnifyingglass") {
                        chooseImport(.places)
                    }
                    Button("Import offline routing pack", systemImage: "signpost.right") { chooseImport(.routing) }
                        .disabled(importingRouting)
                    ForEach(bundledRoutingPacks, id: \.self) { pack in
                        Button("Install \(pack.deletingPathExtension().lastPathComponent) routing", systemImage: "signpost.right") {
                            Task { await install(.success(pack), kind: .routing) }
                        }
                        .disabled(importingRouting)
                    }
                    Button("Installed routing packs", systemImage: "signpost.right") { showingRoutingPacks = true }
                        .disabled(importingRouting)
                } label: {
                    Label("Import map data", systemImage: "plus")
                }
                Menu {
                    if let position = MapPosition(savedPosition) {
                        Button("Save map center", systemImage: "mappin") {
                            let coordinate = position.coordinate
                            pointActions = HouseholdPlace(
                                name: "Dropped pin", latitude: coordinate.latitude, longitude: coordinate.longitude
                            )
                        }
                    }
                    if let selectedPlace {
                        Button("Save \(selectedPlace.name)", systemImage: "bookmark") {
                            pointActions = HouseholdPlace(name: selectedPlace.name, latitude: selectedPlace.latitude,
                                                          longitude: selectedPlace.longitude)
                        }
                    }
                    if let home = household.snapshot.home {
                        Button("Go to home", systemImage: "house") { show(home) }
                    }
                    ForEach(household.snapshot.pins) { pin in
                        Button(pin.name, systemImage: "mappin") { show(pin) }
                    }
                } label: {
                    Label("Saved places", systemImage: "bookmark")
                }
            }
        }
    }

    private var placeSearch: some View {
        MapPlaceSearch(
            index: placeIndex, regions: placeRegions,
            origin: routeOrigin?.coordinate ?? location.fix?.coordinate ?? household.snapshot.home?.coordinate
                ?? MapPosition(savedPosition)?.coordinate,
            savedPlaces: savedPlaces
        ) { place in
            marker = MapMarker(coordinate: place.coordinate, title: place.name)
            selectedPlace = place
            if let origin = routeOrigin {
                routeOrigin = nil
                startRoute(from: origin.coordinate, to: place.coordinate, mode: routeMode)
            }
        }
    }

    private func chooseImport(_ kind: MapImportKind) {
        importKind = kind
        choosing = true
    }

    private func install(_ result: Result<URL, Error>, kind: MapImportKind) async {
        do {
            let file = try result.get()
            switch kind {
            case .tiles:
                let imported = try await storage.importMap(from: file)
                savedPosition = ""
                setMap(imported)
            case .places:
                _ = try await regionStorage.install(file)
                placeRegions = try await regionStorage.installedIndexes()
            case .routing:
                importingRouting = true
                defer { importingRouting = false }
                routeRequest = nil
                _ = try await routeStorage.install(file)
                routingRegions = try await routeStorage.installedPacks()
                route = nil
            }
        } catch {
            if (error as? CocoaError)?.code != .userCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleLocationButton() {
        if locationIsOffscreen, let fix = location.fix {
            marker = MapMarker(coordinate: fix.coordinate, title: "Current position")
            if !location.following { location.toggleFollowing() }
        } else {
            location.toggleFollowing()
        }
    }

    private func show(_ place: HouseholdPlace) {
        selectedPlace = nil
        marker = MapMarker(coordinate: place.coordinate, title: place.name)
    }

    private func setMap(_ map: OfflineMap?) {
        let initialMarker = style == nil ? marker : nil
        self.map = map
        style = OfflineMapStyle(seed: map, downloadedTiles: ExploredMapTiles.directory)
        viewport = nil
        marker = initialMarker
        selectedPlace = nil
        route = nil
        routeRequest = nil
    }

    private var mapTitle: String {
        guard let map else { return "Map" }
        if let position = MapPosition(savedPosition), !map.contains(position.coordinate) {
            return "Map"
        }
        return map.title
    }

    private func findDestination(from place: MapPlace, mode: MapTravelMode) {
        routeOrigin = place
        routeMode = mode
        searchingPlaces = true
    }

    private func routeHere(_ place: HouseholdPlace, from origin: CLLocationCoordinate2D, mode: MapTravelMode) {
        marker = MapMarker(coordinate: place.coordinate, title: place.name)
        startRoute(from: origin, to: place.coordinate, mode: mode)
    }

    private func startRoute(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, mode: MapTravelMode) {
        route = nil
        routeRequest = RouteRequest(
            origin: .init(latitude: origin.latitude, longitude: origin.longitude),
            destination: .init(latitude: destination.latitude, longitude: destination.longitude), mode: mode
        )
    }

    private func supportsOfflineRoute(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D? = nil) -> Bool {
        let start = MapRoute.Point(latitude: origin.latitude, longitude: origin.longitude)
        let end = destination.map { MapRoute.Point(latitude: $0.latitude, longitude: $0.longitude) }
        return routingRegions.contains { installed in
            let bounds = installed.pack.bounds
            return bounds.contains(start) && (end.map(bounds.contains) ?? true)
        }
    }

    private func calculate(_ request: RouteRequest) async {
        defer { if routeRequest?.id == request.id { routeRequest = nil } }
        do {
            let result: MapRoute
            if request.mode == .driving || supportsOfflineRoute(from: request.origin.coordinate, to: request.destination.coordinate) {
                result = try await routeStorage.route(from: request.origin, to: request.destination, mode: request.mode)
            } else if request.mode == .walking, let index = walkingIndex {
                let preview = try await Task.detached {
                    try WalkingRouter(index: index).route(
                        from: WalkingRoute.Point(latitude: request.origin.latitude, longitude: request.origin.longitude),
                        to: WalkingRoute.Point(latitude: request.destination.latitude, longitude: request.destination.longitude)
                    )
                }.value
                result = MapRoute(points: preview.points.map {
                    .init(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                }, steps: [], meters: preview.meters, seconds: nil)
            } else {
                throw RouteError.outsideRegion
            }
            if routeRequest?.id == request.id, !Task.isCancelled {
                route = DisplayedRoute(route: result, mode: request.mode)
            }
        } catch is CancellationError {
        } catch {
            if routeRequest?.id == request.id, !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private func steps(for displayed: DisplayedRoute) -> some View {
        NavigationStack {
            List(displayed.route.steps) { step in
                Button {
                    marker = MapMarker(coordinate: step.start.coordinate, title: step.instruction)
                    showingSteps = false
                } label: {
                    VStack(alignment: .leading) {
                        Text(step.instruction)
                        if step.meters > 0 {
                            Text(Measurement(value: step.meters, unit: UnitLength.meters)
                                .formatted(.measurement(width: .abbreviated, usage: .road)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Route steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { showingSteps = false } }
        }
    }

    private enum MapImportKind {
        case tiles, places, routing

        var contentTypes: [UTType] {
            let extensions: [String]
            switch self {
            case .tiles: extensions = ["pmtiles"]
            case .places: extensions = ["sqlite", "sqlite3"]
            case .routing: extensions = ["tfkroute"]
            }
            return extensions.map { UTType(filenameExtension: $0) ?? .data }
        }
    }

    private struct RouteRequest {
        let id = UUID()
        let origin: MapRoute.Point
        let destination: MapRoute.Point
        let mode: MapTravelMode
    }
}

private struct MapPosition {
    let coordinate: CLLocationCoordinate2D
    let zoom: Double

    var encoded: String {
        "\(coordinate.latitude),\(coordinate.longitude),\(zoom)"
    }

    init(coordinate: CLLocationCoordinate2D, zoom: Double) {
        self.coordinate = coordinate
        self.zoom = zoom
    }

    init?(_ text: String) {
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Double($0) }
        guard fields.count == 3, numbers.count == 3, numbers.allSatisfy(\.isFinite),
              (-90...90).contains(numbers[0]), (-180...180).contains(numbers[1]),
              (0...17).contains(numbers[2]) else { return nil }
        self.init(coordinate: CLLocationCoordinate2D(latitude: numbers[0], longitude: numbers[1]), zoom: numbers[2])
    }
}

private struct MapMarker {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let title: String
}

private struct DisplayedRoute {
    let id = UUID()
    let route: MapRoute
    let mode: MapTravelMode

    var summary: String {
        let distance = Measurement(value: route.meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        guard let seconds = route.seconds else { return "Walking preview · \(distance)" }
        let time = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(mode.title) · \(distance) · \(time)"
    }
}

private struct MapSurface: UIViewRepresentable {
    let style: OfflineMapStyle
    let initialPosition: MapPosition
    let marker: MapMarker?
    let route: DisplayedRoute?
    let savedPlaces: [HouseholdPlace]
    let tileRevision: Int
    let onViewport: (MapViewport, MapPosition) -> Void
    let onHold: (CLLocationCoordinate2D) -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(tileRevision: tileRevision, onViewport: onViewport, onHold: onHold, onError: onError)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let viewer: MLNMapView
        do {
            viewer = MLNMapView(frame: .zero, styleJSON: try style.json(tileRevision: tileRevision))
        } catch {
            viewer = MLNMapView(frame: .zero, styleJSON: #"{"version":8,"sources":{},"layers":[]}"#)
            DispatchQueue.main.async { onError(error) }
        }
        viewer.delegate = context.coordinator
        viewer.logoView.isHidden = true
        viewer.attributionButton.isHidden = true
        viewer.minimumZoomLevel = 0
        viewer.maximumZoomLevel = 17
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.showPointActions(_:))
        )
        viewer.addGestureRecognizer(longPress)
        viewer.setCenter(initialPosition.coordinate, zoomLevel: initialPosition.zoom, animated: false)
        return viewer
    }

    func updateUIView(_ viewer: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onViewport = onViewport
        coordinator.onHold = onHold
        if coordinator.tileRevision != tileRevision {
            coordinator.tileRevision = tileRevision
            do { viewer.styleJSON = try style.json(tileRevision: tileRevision) }
            catch { DispatchQueue.main.async { onError(error) } }
        }
        if coordinator.savedPlaces != savedPlaces {
            viewer.removeAnnotations(coordinator.savedAnnotations)
            coordinator.savedPlaces = savedPlaces
            coordinator.savedAnnotations = savedPlaces.map { place in
                let annotation = MLNPointAnnotation()
                annotation.coordinate = place.coordinate
                annotation.title = place.name
                return annotation
            }
            viewer.addAnnotations(coordinator.savedAnnotations)
        }
        if let marker, coordinator.lastMarker != marker.id {
            coordinator.lastMarker = marker.id
            if let old = coordinator.annotation { viewer.removeAnnotation(old) }
            let annotation = MLNPointAnnotation()
            annotation.coordinate = marker.coordinate
            annotation.title = marker.title
            viewer.addAnnotation(annotation)
            coordinator.annotation = annotation
            viewer.setCenter(marker.coordinate, animated: true)
        }
        if coordinator.lastRoute != route?.id {
            coordinator.lastRoute = route?.id
            if let line = coordinator.routeLine { viewer.removeAnnotation(line) }
            coordinator.routeLine = nil
            if let route {
                let coordinates = route.route.points.map(\.coordinate)
                let line = MLNPolyline(coordinates: coordinates, count: UInt(coordinates.count))
                viewer.addAnnotation(line)
                viewer.showAnnotations(
                    [line], edgePadding: UIEdgeInsets(top: 48, left: 36, bottom: 48, right: 36),
                    animated: true, completionHandler: nil
                )
                coordinator.routeLine = line
            }
        }
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        let onError: (Error) -> Void
        var onViewport: (MapViewport, MapPosition) -> Void
        var onHold: (CLLocationCoordinate2D) -> Void
        var tileRevision: Int
        private var publishedViewport = false
        var lastMarker: UUID?
        var annotation: MLNPointAnnotation?
        var lastRoute: UUID?
        var routeLine: MLNPolyline?
        var savedPlaces: [HouseholdPlace] = []
        var savedAnnotations: [MLNPointAnnotation] = []

        init(tileRevision: Int, onViewport: @escaping (MapViewport, MapPosition) -> Void,
             onHold: @escaping (CLLocationCoordinate2D) -> Void,
             onError: @escaping (Error) -> Void) {
            self.tileRevision = tileRevision
            self.onViewport = onViewport
            self.onHold = onHold
            self.onError = onError
        }

        @objc func showPointActions(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let map = gesture.view as? MLNMapView else { return }
            let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            onHold(coordinate)
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: any Error) {
            onError(error)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            publishViewport(mapView)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            publishViewport(mapView)
        }

        func mapViewDidFinishRenderingMap(_ mapView: MLNMapView, fullyRendered: Bool) {
            if fullyRendered, !publishedViewport { publishViewport(mapView) }
        }

        private func publishViewport(_ mapView: MLNMapView) {
            guard mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
            publishedViewport = true
            let bounds = mapView.visibleCoordinateBounds
            let viewport = MapViewport(
                west: bounds.sw.longitude, south: bounds.sw.latitude,
                east: bounds.ne.longitude, north: bounds.ne.latitude, zoom: mapView.zoomLevel
            )
            let position = MapPosition(coordinate: mapView.centerCoordinate, zoom: mapView.zoomLevel)
            DispatchQueue.main.async { [weak self] in self?.onViewport(viewport, position) }
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            .systemBlue
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            4
        }
    }
}

@MainActor
private final class MapLocation: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var fix: CLLocation?
    @Published private(set) var message: String?
    @Published private(set) var following = false
    private let manager = CLLocationManager()
    private var visible = false
    private var hasOpenedMap = false
    private var needsInitialFix = false
    private var requestedAuthorization = false
    private var requestingFix = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
    }

    func toggleFollowing() {
        needsInitialFix = false
        following.toggle()
        if following {
            message = "Finding your position"
            updateTracking()
        } else {
            manager.stopUpdatingLocation()
            requestingFix = false
            message = nil
        }
    }

    func setVisible(_ visible: Bool, centerInitially: Bool = false) {
        self.visible = visible
        if visible, !hasOpenedMap {
            hasOpenedMap = true
            needsInitialFix = centerInitially || manager.authorizationStatus == .notDetermined
        }
        updateTracking()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateTracking()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        requestingFix = false
        guard visible, following || needsInitialFix else { return }
        needsInitialFix = false
        fix = locations.last(where: { $0.horizontalAccuracy >= 0 })
        message = fix == nil ? "Could not get a location." : nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        requestingFix = false
        guard visible, following || needsInitialFix else { return }
        needsInitialFix = false
        message = "Could not get a location."
    }

    private func updateTracking() {
        guard visible, following || needsInitialFix else {
            manager.stopUpdatingLocation()
            requestingFix = false
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            if !requestedAuthorization {
                requestedAuthorization = true
                manager.requestWhenInUseAuthorization()
            }
        case .authorizedAlways, .authorizedWhenInUse:
            if following {
                requestingFix = false
                manager.startUpdatingLocation()
            } else if !requestingFix {
                requestingFix = true
                manager.requestLocation()
            }
        default:
            needsInitialFix = false
            following = false
            message = "Location access is off."
        }
    }
}
