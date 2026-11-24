import Combine
import CoreLocation
import Foundation

struct HouseholdPlace: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var note = ""
    var latitude: Double
    var longitude: Double

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
    var notes = ""
    var home: HouseholdPlace?
    var pins: [HouseholdPlace] = []
}

@MainActor
final class HouseholdStore: ObservableObject {
    @Published private(set) var snapshot = HouseholdSnapshot()
    private(set) var loadError: Error?
    private let file: URL

    init(file: URL = URL.applicationSupportDirectory.appendingPathComponent("Household/household.json")) {
        self.file = file
        do {
            let saved = try JSONDecoder().decode(HouseholdSnapshot.self, from: Data(contentsOf: file))
            guard saved.home?.isValid != false, saved.pins.allSatisfy(\.isValid),
                  Set(saved.pins.map(\.id)).count == saved.pins.count else {
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

    private func save(_ next: HouseholdSnapshot) throws {
        if let loadError { throw loadError }
        guard snapshot != next else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        snapshot = next
    }

    private enum PlaceError: LocalizedError {
        case invalid

        var errorDescription: String? { "Enter a name and valid coordinates for this place." }
    }
}
