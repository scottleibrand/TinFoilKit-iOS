import Combine
import CoreLocation
import Foundation

struct HouseholdPlace: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var note = ""
    var latitude: Double
    var longitude: Double
    var desktopPinID: String?
    var desktopHomeZoom: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var coordinateText: String {
        MapCoordinateText.decimal(coordinate)
    }

    var isValid: Bool {
        CLLocationCoordinate2DIsValid(coordinate) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct HouseholdSnapshot: Codable, Equatable, Sendable {
    static let maxResources = 100

    var notes = ""
    var home: HouseholdPlace?
    var pins: [HouseholdPlace] = []
    var resources: [HouseholdResource]?

    var isValid: Bool {
        let resources = resources ?? []
        return home?.isValid != false && pins.allSatisfy(\.isValid) && Set(pins.map(\.id)).count == pins.count &&
            resources.count <= Self.maxResources && resources.allSatisfy(\.isValid) &&
            Set(resources.map(\.id)).count == resources.count
    }
}

@MainActor
final class HouseholdStore: ObservableObject {
    @Published private(set) var snapshot = HouseholdSnapshot()
    @Published private(set) var loadError: Error?
    private let file: URL

    init(file: URL = URL.applicationSupportDirectory.appendingPathComponent("Household/household.json")) {
        self.file = file
        do {
            let saved = try JSONDecoder().decode(HouseholdSnapshot.self, from: Data(contentsOf: file))
            guard saved.isValid else {
                throw CocoaError(.fileReadCorruptFile)
            }
            snapshot = saved
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        } catch {
            loadError = error
        }
    }

    func saveNotes(_ notes: String) throws {
        var next = snapshot
        next.notes = notes
        try save(next)
    }

    func appendGuestNote(_ note: String) throws {
        let entry = "Guest note\n" + note
        let existing = snapshot.notes
        try saveNotes(existing.isEmpty ? entry : existing + "\n\n" + entry)
    }

    func setHome(_ home: HouseholdPlace?) throws {
        guard home?.isValid != false else { throw PlaceError.invalid }
        var next = snapshot
        next.home = home
        try save(next)
    }

    func savePin(_ pin: HouseholdPlace) throws {
        guard pin.isValid else { throw PlaceError.invalid }
        var next = snapshot
        if let existing = next.pins.firstIndex(where: { $0.id == pin.id }) {
            next.pins[existing] = pin
        } else {
            next.pins.append(pin)
        }
        try save(next)
    }

    func removePin(_ id: UUID) throws {
        var next = snapshot
        next.pins.removeAll { $0.id == id }
        try save(next)
    }

    func saveResource(_ resource: HouseholdResource) throws {
        guard resource.isValid else { throw ResourceError.invalid }
        var next = snapshot
        var resources = next.resources ?? []
        if let index = resources.firstIndex(where: { $0.id == resource.id }) {
            resources[index] = resource
        } else {
            guard resources.count < HouseholdSnapshot.maxResources else { throw ResourceError.limitReached }
            resources.append(resource)
        }
        next.resources = resources
        try save(next)
    }

    func removeResource(_ id: UUID) throws {
        var next = snapshot
        guard var resources = next.resources else { return }
        resources.removeAll { $0.id == id }
        next.resources = resources.isEmpty ? nil : resources
        try save(next)
    }

    func restore(_ next: HouseholdSnapshot) throws {
        guard next.isValid else { throw PlaceError.invalidHousehold }
        guard loadError != nil || snapshot != next else { return }
        let data = try JSONEncoder().encode(next)
        if loadError != nil {
            let directory = file.deletingLastPathComponent()
            let recovery = directory.appendingPathComponent(
                "household-unreadable-\(UUID().uuidString).json"
            )
            try FileManager.default.copyItem(at: file, to: recovery)
        }
        try write(data)
        snapshot = next
        loadError = nil
    }

    private func save(_ next: HouseholdSnapshot) throws {
        if let loadError { throw loadError }
        guard snapshot != next else { return }
        try write(JSONEncoder().encode(next))
        snapshot = next
    }

    private func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private enum PlaceError: LocalizedError {
        case invalid, invalidHousehold

        var errorDescription: String? {
            switch self {
            case .invalid: "Enter a name and valid coordinates for this place."
            case .invalidHousehold: "The household backup contains invalid or duplicate locations or supplies."
            }
        }
    }

    private enum ResourceError: LocalizedError {
        case invalid, limitReached

        var errorDescription: String? {
            switch self {
            case .invalid: "Check the supply name, amounts, and units."
            case .limitReached: "The household already has \(HouseholdSnapshot.maxResources) supplies."
            }
        }
    }
}
