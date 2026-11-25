import CryptoKit
import Foundation

/// Interchanges the desktop kit's data/notes.txt and data/places.json files.
enum DesktopHouseholdFiles {
    private static let utf8BOM: [UInt8] = [0xef, 0xbb, 0xbf]
    private static let maxNotes = 100_000
    private static let maxPins = 1_000
    private static let defaultHomeZoom = 12.0
    static let maxNotesBytes = maxNotes * 4 + utf8BOM.count
    // A desktop file can hold 1,000 pins, each with 5,000 scalars and up to 12 JSON bytes per scalar.
    static let maxPlacesBytes = 64 * 1_024 * 1_024

    static func applying(notes: Data? = nil, places: Data? = nil, to snapshot: HouseholdSnapshot) throws -> HouseholdSnapshot {
        var result = snapshot
        if let notes {
            guard notes.count <= maxNotesBytes,
                  let decoded = String(data: removingBOM(notes), encoding: .utf8),
                  decoded.unicodeScalars.count <= maxNotes else { throw FileError.invalidNotes }
            result.notes = decoded
        }
        if let places {
            guard places.count <= maxPlacesBytes else { throw FileError.invalidPlaces }
            let decoded: Places
            do {
                decoded = try JSONDecoder().decode(Places.self, from: removingBOM(places))
            } catch {
                throw FileError.invalidPlaces
            }

            if decoded.hasHome {
                result.home = try decoded.home.map { home in
                    let label = home.label ?? ""
                    guard label.unicodeScalars.count <= 200,
                          home.zoom.map({ (0...22).contains($0) }) != false else {
                        throw FileError.invalidPlaces
                    }
                    let name = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Home" : label
                    let sameLocation = snapshot.home?.latitude == home.lat && snapshot.home?.longitude == home.lon
                    let zoom = home.zoom ?? (sameLocation ? snapshot.home?.desktopHomeZoom : nil)
                    let place = HouseholdPlace(
                        id: snapshot.home?.id ?? stableID("home"), name: name,
                        note: sameLocation ? snapshot.home?.note ?? "" : "",
                        latitude: home.lat, longitude: home.lon,
                        desktopHomeZoom: zoom == defaultHomeZoom ? nil : zoom
                    )
                    guard place.isValid else { throw FileError.invalidPlaces }
                    return place
                }
            }
            if let pins = decoded.pins {
                guard pins.count <= maxPins else { throw FileError.invalidPlaces }
                var encountered: Set<UUID> = []
                result.pins = try pins.map { pin in
                    guard validDesktopID(pin.id) else { throw FileError.invalidPlaces }
                    let id = pinUUID(pin.id)
                    let place = HouseholdPlace(
                        id: id, name: pin.name, note: pin.note ?? "", latitude: pin.lat, longitude: pin.lon,
                        desktopPinID: pin.id == id.uuidString.lowercased() ? nil : pin.id
                    )
                    guard validPin(place), encountered.insert(id).inserted else { throw FileError.invalidPlaces }
                    return place
                }
            }
        }
        return result
    }

    static func encodeNotes(_ snapshot: HouseholdSnapshot) throws -> Data {
        guard snapshot.notes.unicodeScalars.count <= maxNotes else { throw FileError.invalidNotes }
        return Data(snapshot.notes.utf8)
    }

    static func encodePlaces(_ snapshot: HouseholdSnapshot) throws -> Data {
        guard snapshot.pins.count <= maxPins, snapshot.pins.allSatisfy(validPin),
              Set(snapshot.pins.map(\.id)).count == snapshot.pins.count,
              snapshot.home.map({ $0.isValid && $0.name.unicodeScalars.count <= 200 }) != false else {
            throw FileError.invalidPlaces
        }
        let home = snapshot.home.map { place in
            let zoom = place.desktopHomeZoom.flatMap { (0...22).contains($0) ? $0 : nil } ?? defaultHomeZoom
            return Home(lat: place.latitude, lon: place.longitude, label: place.name, zoom: zoom)
        }
        let pins = snapshot.pins.map {
            Pin(id: desktopID(for: $0), name: $0.name, note: $0.note, lat: $0.latitude, lon: $0.longitude)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Places(home: home, pins: pins))
    }

    private static func removingBOM(_ data: Data) -> Data {
        data.starts(with: utf8BOM) ? data.dropFirst(utf8BOM.count) : data
    }

    private static func validPin(_ pin: HouseholdPlace) -> Bool {
        pin.isValid && pin.name.unicodeScalars.count <= 200 && pin.note.unicodeScalars.count <= 5_000
    }

    private static func validDesktopID(_ id: String) -> Bool {
        let bytes = id.utf8
        return (1...64).contains(bytes.count) && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func pinUUID(_ id: String) -> UUID {
        UUID(uuidString: id) ?? stableID("pin:" + id)
    }

    private static func desktopID(for pin: HouseholdPlace) -> String {
        guard let id = pin.desktopPinID, validDesktopID(id), pinUUID(id) == pin.id else {
            return pin.id.uuidString.lowercased()
        }
        return id
    }

    private static func stableID(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("TinfoilKit.desktop.household:" + key).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private enum FileError: LocalizedError {
        case invalidNotes, invalidPlaces

        var errorDescription: String? {
            switch self {
            case .invalidNotes: "Choose a UTF-8 notes.txt file with at most 100,000 characters."
            case .invalidPlaces: "The places.json file contains invalid household locations."
            }
        }
    }

    private struct Places: Codable {
        let hasHome: Bool
        let home: Home?
        let pins: [Pin]?

        enum CodingKeys: String, CodingKey { case home, pins }

        init(home: Home?, pins: [Pin]) {
            hasHome = true
            self.home = home
            self.pins = pins
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasHome = container.contains(.home)
            let hasPins = container.contains(.pins)
            guard hasHome || hasPins else { throw FileError.invalidPlaces }
            home = try container.decodeIfPresent(Home.self, forKey: .home)
            pins = hasPins ? try container.decode([Pin].self, forKey: .pins) : nil
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(home, forKey: .home)
            try container.encode(pins, forKey: .pins)
        }
    }

    private struct Home: Codable {
        let lat: Double
        let lon: Double
        let label: String?
        let zoom: Double?
    }

    private struct Pin: Codable {
        let id: String
        let name: String
        let note: String?
        let lat: Double
        let lon: Double
    }
}
