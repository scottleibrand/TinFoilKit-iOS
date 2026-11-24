import CoreLocation
import MapLibre
import SwiftUI
import UniformTypeIdentifiers

struct OfflineMapView: View {
    @State private var storage = MapStorage()
    @StateObject private var location = MapLocation()
    @State private var map: OfflineMap?
    @State private var style: URL?
    @State private var choosing = false
    @State private var searchingPlaces = false
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var marker: MapMarker?
    @State private var selectedPlace: MapPlace?
    @State private var routeOrigin: MapPlace?
    @State private var route: DisplayedRoute?
    @State private var findingRoute = false

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
            Group {
                if let map, let style {
                    MapSurface(map: map, style: style, marker: marker, route: route) { error in
                        errorMessage = error.localizedDescription
                    }
                    .id(style)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(alignment: .leading, spacing: 5) {
                            if let fix = location.fix, !map.contains(fix.coordinate) {
                                Text("Your position is outside this map.")
                            } else if let message = location.message {
                                Text(message)
                            }
                            Text(map.title)
                                .font(.footnote.weight(.semibold))
                            if findingRoute {
                                ProgressView("Finding walking route")
                            } else if let route {
                                Text("Walking preview · \(Measurement(value: route.route.meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))")
                                Button("Clear walking route") { self.route = nil }
                            } else if let selectedPlace, walkingIndex != nil {
                                Text(selectedPlace.name)
                                Button("Start walk here") {
                                    routeOrigin = selectedPlace
                                    searchingPlaces = true
                                }
                            } else if let selectedPlace {
                                Text(selectedPlace.name)
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
                        Button("Import map") { choosing = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if map != nil {
                    if placeIndex != nil {
                        Button("Search places", systemImage: "magnifyingglass") { searchingPlaces = true }
                    }
                    Button("Find my location", systemImage: "location") { location.request() }
                    Button("Import map", systemImage: "plus") { choosing = true }
                }
            }
            .sheet(isPresented: $searchingPlaces, onDismiss: { routeOrigin = nil }) {
                if let placeIndex {
                    MapPlaceSearch(index: placeIndex) { place in
                        marker = MapMarker(coordinate: place.coordinate, title: place.name)
                        selectedPlace = place
                        if let origin = routeOrigin, let index = walkingIndex {
                            routeOrigin = nil
                            Task { await previewRoute(from: origin, to: place, index: index) }
                        }
                    }
                }
            }
            .onChange(of: location.fix?.timestamp) {
                if let fix = location.fix {
                    marker = MapMarker(coordinate: fix.coordinate, title: "Current position")
                }
            }
            .fileImporter(
                isPresented: $choosing,
                allowedContentTypes: [UTType(filenameExtension: "pmtiles") ?? .data]
            ) { result in
                Task {
                    do {
                        try setMap(await storage.importMap(from: result.get()))
                    } catch { errorMessage = error.localizedDescription }
                }
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
                guard map == nil else { return }
                do { try setMap(await storage.current()) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func setMap(_ map: OfflineMap?) throws {
        let nextStyle = try map?.makeStyle()
        self.map = map
        style = nextStyle
        marker = nil
        selectedPlace = nil
        route = nil
    }

    private func previewRoute(from origin: MapPlace, to destination: MapPlace, index: URL) async {
        findingRoute = true
        defer { findingRoute = false }
        do {
            let result = try await Task.detached {
                try WalkingRouter(index: index).route(
                    from: WalkingRoute.Point(latitude: origin.latitude, longitude: origin.longitude),
                    to: WalkingRoute.Point(latitude: destination.latitude, longitude: destination.longitude)
                )
            }.value
            if walkingIndex == index { route = DisplayedRoute(route: result) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MapMarker {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let title: String
}

private struct DisplayedRoute {
    let id = UUID()
    let route: WalkingRoute
}

private struct MapSurface: UIViewRepresentable {
    let map: OfflineMap
    let style: URL
    let marker: MapMarker?
    let route: DisplayedRoute?
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onError: onError)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let viewer = MLNMapView(frame: .zero, styleURL: style)
        viewer.delegate = context.coordinator
        viewer.logoView.isHidden = true
        viewer.attributionButton.isHidden = true
        viewer.maximumZoomLevel = Double(map.maxZoom) + 2
        viewer.setCenter(map.center, zoomLevel: 11, animated: false)
        let corners = [
            CLLocationCoordinate2D(latitude: map.minLatitude, longitude: map.minLongitude),
            CLLocationCoordinate2D(latitude: map.minLatitude, longitude: map.maxLongitude),
            CLLocationCoordinate2D(latitude: map.maxLatitude, longitude: map.maxLongitude),
            CLLocationCoordinate2D(latitude: map.maxLatitude, longitude: map.minLongitude)
        ]
        viewer.addAnnotation(MLNPolygon(coordinates: corners, count: UInt(corners.count)))
        return viewer
    }

    func updateUIView(_ viewer: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        if let marker, coordinator.lastMarker != marker.id {
            coordinator.lastMarker = marker.id
            if let old = coordinator.annotation { viewer.removeAnnotation(old) }
            if map.contains(marker.coordinate) {
                let annotation = MLNPointAnnotation()
                annotation.coordinate = marker.coordinate
                annotation.title = marker.title
                viewer.addAnnotation(annotation)
                coordinator.annotation = annotation
                viewer.setCenter(marker.coordinate, animated: true)
            }
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
        var lastMarker: UUID?
        var annotation: MLNPointAnnotation?
        var lastRoute: UUID?
        var routeLine: MLNPolyline?

        init(onError: @escaping (Error) -> Void) {
            self.onError = onError
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: any Error) {
            onError(error)
        }

        func mapView(_ mapView: MLNMapView, fillColorForPolygonAnnotation annotation: MLNPolygon) -> UIColor {
            .clear
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            annotation is MLNPolyline ? .systemBlue : .systemOrange
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
    private let manager = CLLocationManager()
    private var waiting = false

    override init() {
        super.init()
        manager.delegate = self
    }

    func request() {
        waiting = true
        message = "Finding your position"
        requestWhenAuthorized(manager)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if waiting { requestWhenAuthorized(manager) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        waiting = false
        fix = locations.last
        message = fix == nil ? "Could not get a location." : nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        waiting = false
        message = "Could not get a location."
    }

    private func requestWhenAuthorized(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            waiting = false
            message = "Location access is off."
        }
    }
}
