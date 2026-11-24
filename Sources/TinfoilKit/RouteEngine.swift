import CoreLocation
import Foundation
import TFKValhalla

final class RouteEngine {
    private let handle: OpaquePointer

    init(folder: URL) throws {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("Routing", isDirectory: true) else {
            throw RouteError.engineUnavailable
        }
        let timezone = resources.appendingPathComponent("tzdata", isDirectory: true)
        guard FileManager.default.fileExists(atPath: timezone.path),
              let defaults = try JSONSerialization.jsonObject(
                with: Data(contentsOf: resources.appendingPathComponent("default.json"))
              ) as? [String: Any],
              var graphSettings = defaults["mjolnir"] as? [String: Any] else {
            throw RouteError.engineUnavailable
        }
        var error: UnsafeMutablePointer<CChar>?
        guard tfk_valhalla_set_tzdata(timezone.path, &error) != 0 else {
            tfk_valhalla_string_free(error)
            throw RouteError.engineUnavailable
        }
        let config = folder.appendingPathComponent("engine.json")
        let graph = folder.appendingPathComponent("tiles.tar")
        graphSettings["tile_extract"] = graph.path
        graphSettings["tile_dir"] = folder.appendingPathComponent("tiles").path
        graphSettings["tile_url"] = ""
        graphSettings["traffic_extract"] = ""
        graphSettings["max_cache_size"] = 64 * 1024 * 1024
        graphSettings["use_lru_mem_cache"] = true
        graphSettings["lru_mem_cache_hard_control"] = true
        var settings = defaults
        settings["mjolnir"] = graphSettings
        try JSONSerialization.data(withJSONObject: settings).write(to: config, options: .atomic)
        guard let handle = tfk_valhalla_open(config.path, &error) else {
            tfk_valhalla_string_free(error)
            throw RouteError.engineUnavailable
        }
        self.handle = handle
    }

    deinit { tfk_valhalla_close(handle) }

    func route(from origin: MapRoute.Point, to destination: MapRoute.Point, mode: MapTravelMode) throws -> MapRoute {
        let request: [String: Any] = [
            "locations": [origin, destination].map { ["lat": $0.latitude, "lon": $0.longitude, "radius": 250] },
            "costing": mode.costing,
            "units": "kilometers",
            "shape_format": "polyline6"
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        var error: UnsafeMutablePointer<CChar>?
        guard let response = tfk_valhalla_route(handle, json, &error) else {
            tfk_valhalla_string_free(error)
            throw RouteError.noRoute
        }
        defer { tfk_valhalla_string_free(response) }
        return try ValhallaRouteResponse.decode(Data(String(cString: response).utf8))
    }
}
