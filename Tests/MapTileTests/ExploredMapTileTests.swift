import XCTest
import MapLibre
@testable import TinfoilKit

final class ExploredMapTileTests: XCTestCase {
    func testDecodesRouteDistanceAndManeuverCoordinates() throws {
        let response = #"""
        {"trip":{"status":0,"summary":{"length":1.036,"time":108.693},"legs":[
          {"shape":"_mdryA~_iugF?_XozD??~xFnzD??g^","maneuvers":[
            {"begin_shape_index":0,"instruction":"Drive east on East Main.","length":0.030},
            {"begin_shape_index":2,"instruction":"Turn left onto North Bypass.","length":0.310}
          ]}
        ]}}
        """#
        let route = try ValhallaRouteResponse.decode(Data(response.utf8))
        XCTAssertEqual(route.meters, 1036, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(route.seconds), 108.693, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(route.points.first).longitude, -122.0004, accuracy: 0.000001)
        XCTAssertEqual(route.steps[1].start.latitude, route.points[2].latitude)
        XCTAssertThrowsError(try ValhallaRouteResponse.decodePolyline("?"))
    }

    func testCoordinatesRoundTripAcrossDecimalAndDMSFormats() throws {
        let original = try XCTUnwrap(MapCoordinateText.parse("48.3404, -122.3414"))
        let dms = MapCoordinateText.degreesMinutesSeconds(original)
        let restored = try XCTUnwrap(MapCoordinateText.parse(dms))
        XCTAssertEqual(restored.latitude, original.latitude, accuracy: 0.00002)
        XCTAssertEqual(restored.longitude, original.longitude, accuracy: 0.00002)
        XCTAssertNil(MapCoordinateText.parse("48°20′60″N, 122°20′29″W"))
        XCTAssertNil(MapCoordinateText.parse("91, 20"))
        XCTAssertNil(MapCoordinateText.parse("45 N 100 W"))
    }

    func testGoogleMapsLinkContainsOnlyDestinationCoordinates() throws {
        let url = try XCTUnwrap(MapCoordinateText.googleMapsURL(.init(latitude: -31.176, longitude: 115.432)))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.google.com")
        XCTAssertEqual(components.path, "/maps/search/")
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: "-31.176000,115.432000")
        ])
        XCTAssertNil(MapCoordinateText.googleMapsURL(.init(latitude: 91, longitude: 0)))
    }

    func testWaterStyleFillsPolygonsAndStrokesWaterways() throws {
        let style = OfflineMapStyle(seed: nil, downloadedTiles: URL.temporaryDirectory)
        let json = try JSONSerialization.jsonObject(with: Data(style.json(tileRevision: 1).utf8))
        let document = try XCTUnwrap(json as? [String: Any])
        let layers = try XCTUnwrap(document["layers"] as? [[String: Any]])
        let water = try XCTUnwrap(layers.first { $0["id"] as? String == "downloaded-water" })
        let waterways = try XCTUnwrap(layers.first { $0["id"] as? String == "downloaded-waterways" })

        XCTAssertEqual(water["type"] as? String, "fill")
        XCTAssertEqual(waterways["type"] as? String, "line")
        for (layer, geometry) in [(water, "Polygon"), (waterways, "LineString")] {
            XCTAssertEqual(layer["source-layer"] as? String, "water")
            XCTAssertEqual(layer["filter"] as? NSArray, ["==", ["geometry-type"], geometry] as NSArray)
        }
    }

    func testTileIDsMatchPMTilesSpecification() {
        XCTAssertEqual(MapTile(zoom: 0, x: 0, y: 0).id, 0)
        XCTAssertEqual(MapTile(zoom: 1, x: 1, y: 0).id, 4)
        XCTAssertEqual(MapTile(zoom: 12, x: 3423, y: 1763).id, 19_078_479)
    }

    func testViewportWrapsAtAntimeridian() {
        let view = MapViewport(west: 179.8, south: 48, east: -179.8, north: 48.2, zoom: 7.5)
        let visible = view.tiles.filter { $0.zoom == 7 }
        XCTAssertEqual(Set(visible.map(\.x)), Set([0, 127]))
        XCTAssertTrue(view.contains(latitude: 48.1, longitude: 179.9))
        XCTAssertTrue(view.contains(latitude: 48.1, longitude: -179.9))
        XCTAssertFalse(view.contains(latitude: 48.1, longitude: 179))
        XCTAssertFalse(view.contains(latitude: 47.9, longitude: -179.9))
    }

    func testSavedTileIsAvailableInANewStoreWithDownloadsDisabled() async throws {
        let fixture = try XCTUnwrap(Bundle.main.url(
            forResource: "seattle", withExtension: "pmtiles", subdirectory: "map-assets"
        ))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let view = MapViewport(west: -122.37, south: 47.59, east: -122.32, north: 47.62, zoom: 12)
        let tile = try XCTUnwrap(view.tiles.first)
        let store = ExploredMapTiles(directory: output, source: fixture)
        let skipped = await store.save(tile, seed: nil, download: false)
        XCTAssertEqual(skipped, .missing)
        let saved = await store.save(tile, seed: nil, download: true)
        XCTAssertEqual(saved, .saved)
        let file = output.appendingPathComponent("\(tile.zoom)/\(tile.x)/\(tile.y).pbf")
        XCTAssertGreaterThan(try Data(contentsOf: file).count, 0)

        let reopened = ExploredMapTiles(directory: output, source: output.appendingPathComponent("unavailable.pmtiles"))
        let offline = await reopened.save(tile, seed: nil, download: false)
        XCTAssertEqual(offline, .available)
        let bytes = try await store.savedBytes()
        XCTAssertGreaterThan(bytes, 0)
        try await store.clearSavedTiles()
        let empty = try await store.savedBytes()
        XCTAssertEqual(empty, 0)
        let afterClear = await reopened.save(tile, seed: nil, download: false)
        XCTAssertEqual(afterClear, .missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
    }

    func testMapDownloadPolicyRespectsTheNetworkAndOffSwitch() {
        XCTAssertFalse(MapDownloadPolicy.off.permitsDownloads(online: true, wifi: true))
        XCTAssertFalse(MapDownloadPolicy.wifiOnly.permitsDownloads(online: true, wifi: false))
        XCTAssertTrue(MapDownloadPolicy.wifiOnly.permitsDownloads(online: true, wifi: true))
        XCTAssertTrue(MapDownloadPolicy.wifiAndCellular.permitsDownloads(online: true, wifi: false))
        XCTAssertFalse(MapDownloadPolicy.wifiAndCellular.permitsDownloads(online: false, wifi: false))
    }

    @MainActor
    func testMapDownloadPreferenceSurvivesReopening() throws {
        let suite = "MapDownloads-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let exploration = MapExploration(defaults: defaults)
        XCTAssertEqual(exploration.policy, .wifiAndCellular)
        exploration.setPolicy(.off)
        XCTAssertEqual(MapExploration(defaults: defaults).policy, .off)
    }

    @MainActor
    func testMapLibreRendersNewLocalTilesWithoutMovingCamera() async throws {
        let fixture = try XCTUnwrap(Bundle.main.url(
            forResource: "seattle", withExtension: "pmtiles", subdirectory: "map-assets"
        ))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let style = OfflineMapStyle(seed: nil, downloadedTiles: output)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let map = MLNMapView(frame: window.bounds, styleJSON: try style.json(tileRevision: 0))
        controller.view = map
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKey()
        }
        map.setCenter(CLLocationCoordinate2D(latitude: 47.608, longitude: -122.335), zoomLevel: 12, animated: false)

        let clock = ContinuousClock()
        let styleDeadline = clock.now + .seconds(10)
        while map.style == nil, clock.now < styleDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(map.style?.source(withIdentifier: "downloaded-0"))
        let layers: Set<String> = ["downloaded-roads"]
        XCTAssertTrue(map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: layers).isEmpty)
        let center = map.centerCoordinate
        let zoom = map.zoomLevel
        let store = ExploredMapTiles(directory: output, source: fixture)
        let viewport = MapViewport(west: -122.42, south: 47.54, east: -122.25, north: 47.66, zoom: 12)
        for tile in viewport.tiles {
            _ = await store.save(tile, seed: nil, download: true)
        }
        map.styleJSON = try style.json(tileRevision: 1)

        let deadline = clock.now + .seconds(20)
        while clock.now < deadline {
            if !map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: layers).isEmpty {
                XCTAssertEqual(map.centerCoordinate.latitude, center.latitude, accuracy: 0.000001)
                XCTAssertEqual(map.centerCoordinate.longitude, center.longitude, accuracy: 0.000001)
                XCTAssertEqual(map.zoomLevel, zoom, accuracy: 0.000001)
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("MapLibre did not render road features from the saved tile files")
    }
}
