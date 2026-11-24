import CoreLocation
import Foundation

@main
struct VerifyRegionalPlaceIndex {
    static func main() throws {
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        let index = RegionalPlaceIndex(file: file)
        let metadata = try index.metadata()
        precondition(metadata.region == "Synthetic test")
        precondition(metadata.license == "ODbL-1.0")
        precondition(metadata.placeCount == 8)
        precondition(metadata.dataVersion == "synthetic-v1")
        precondition(metadata.bounds?.contains(CLLocationCoordinate2D(latitude: 47, longitude: -122)) == true)

        let addresses = try index.search("123 cafe examp")
        precondition(addresses.map(\.address) == ["123 Café Avenue, Exampleville, 98100"])
        let square = try index.search("8 beacon square")
        precondition(square.map(\.name) == ["8 Beacon Square"])
        let fireStation = try index.search("fire station")
        precondition(fireStation.map(\.name) == ["Station 7"])
        let noMatches = try index.search("\" ( * ) ")
        precondition(noMatches.isEmpty)

        let local = CLLocationCoordinate2D(latitude: 47.610, longitude: -122.330)
        let nearbyHospitals = try index.nearest(.hospital, to: local)
        precondition(nearbyHospitals.map(\.place.name) == ["Central Hospital", "North Hospital"])
        precondition((110...112).contains(nearbyHospitals[0].distanceMeters))
        let limitedHospitals = try index.nearest(.hospital, to: local, limit: 1)
        precondition(limitedHospitals.map(\.place.name) == ["Central Hospital"])
        let farHospitals = try index.nearest(.hospital, to: local, radiusMeters: 100)
        precondition(farHospitals.isEmpty)
        let pharmacies = try index.nearest(.pharmacy, to: local)
        precondition(pharmacies.map(\.place.name) == ["Pharmacy"])

        let dateLine = CLLocationCoordinate2D(latitude: 0, longitude: -179.995)
        let shelters = try index.nearest(.shelter, to: dateLine, radiusMeters: 3_000)
        precondition(shelters.map(\.place.name) == ["East Shelter", "West Shelter"])

        do {
            let oldFile = URL(fileURLWithPath: CommandLine.arguments[2])
            _ = try RegionalPlaceIndex(file: oldFile).metadata()
            preconditionFailure("Unexpected acceptance of an older schema")
        } catch RegionalPlaceIndex.IndexError.unsupportedVersion {
            print("Verified address prefixes, accents, amenities, geodesic distance, antimeridian search, and schema rejection")
        }
    }
}
