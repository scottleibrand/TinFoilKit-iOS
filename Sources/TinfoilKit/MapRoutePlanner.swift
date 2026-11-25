import SwiftUI

struct MapRoutePlanner: View {
    let index: URL?
    let regions: [RegionalPlaceStorage.Installed]
    let savedPlaces: [HouseholdPlace]
    let currentLocation: MapPlace?
    let coverage: [RoutingPack.Bounds]
    let walkingPreview: RoutingPack.Bounds?
    let onPlan: (MapPlace, MapPlace, MapTravelMode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var origin: MapPlace?
    @State private var destination: MapPlace?
    @State private var mode: MapTravelMode = .walking
    @State private var choosing: Endpoint?

    init(index: URL?, regions: [RegionalPlaceStorage.Installed], savedPlaces: [HouseholdPlace],
         home: HouseholdPlace?, currentLocation: MapPlace?, destination: MapPlace?,
         coverage: [RoutingPack.Bounds], walkingPreview: RoutingPack.Bounds?,
         onPlan: @escaping (MapPlace, MapPlace, MapTravelMode) -> Void) {
        self.index = index
        self.regions = regions
        self.savedPlaces = savedPlaces
        self.currentLocation = currentLocation
        self.coverage = coverage
        self.walkingPreview = walkingPreview
        self.onPlan = onPlan
        _origin = State(initialValue: home.map(MapPlace.saved) ?? currentLocation)
        _destination = State(initialValue: destination)
    }

    private var availability: MapRouteDraft.Availability {
        let draft = MapRouteDraft(origin: origin.map(\.routePoint), destination: destination.map(\.routePoint), mode: mode)
        return draft.availability(coverage: coverage, walkingPreview: walkingPreview)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    endpoint(.origin, place: origin)
                    endpoint(.destination, place: destination)
                    if origin != nil, destination != nil {
                        Button("Swap endpoints", systemImage: "arrow.up.arrow.down") { (origin, destination) = (destination, origin) }
                    }
                }
                Section {
                    Picker("Travel mode", selection: $mode) {
                        ForEach(MapTravelMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Button("Find offline route", systemImage: "signpost.right") {
                        guard let origin, let destination, availability == .ready else { return }
                        onPlan(origin, destination, mode)
                        dismiss()
                    }
                    .disabled(availability != .ready)
                } footer: {
                    switch availability {
                    case .needsEndpoints: Text("Choose a starting point and destination.")
                    case .sameLocation: Text("Choose two different locations.")
                    case .outsideCoverage:
                        Text(coverage.isEmpty && (mode == .driving || walkingPreview == nil)
                             ? "Install an offline routing pack from Map to plan this route."
                             : RouteError.outsideRegion.localizedDescription)
                    case .ready: EmptyView()
                    }
                }
            }
            .navigationTitle("Directions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(item: $choosing) { endpoint in
                MapPlaceSearch(index: index, regions: regions,
                               origin: (endpoint == .origin ? origin ?? destination : origin)?.coordinate,
                               savedPlaces: savedPlaces, currentLocation: currentLocation) { place in
                    switch endpoint {
                    case .origin: origin = place
                    case .destination: destination = place
                    }
                }
            }
        }
    }

    private func endpoint(_ endpoint: Endpoint, place: MapPlace?) -> some View {
        Button {
            choosing = endpoint
        } label: {
            LabeledContent(endpoint.title, value: place?.name ?? "Choose a place")
        }
    }

    private enum Endpoint: String, Identifiable {
        case origin, destination

        var id: Self { self }
        var title: String { self == .origin ? "From" : "To" }
    }
}

private extension MapPlace {
    var routePoint: MapRoute.Point { .init(latitude: latitude, longitude: longitude) }
}
