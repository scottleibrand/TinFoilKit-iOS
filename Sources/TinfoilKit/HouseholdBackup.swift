import Foundation

enum HouseholdBackup {
    enum Kind: Sendable {
        case native
        case desktopNotes
        case desktopPlaces

        var maximumBytes: Int {
            switch self {
            case .native: HouseholdBackup.maximumBytes
            case .desktopNotes: DesktopHouseholdFiles.maxNotesBytes
            case .desktopPlaces: DesktopHouseholdFiles.maxPlacesBytes
            }
        }
    }

    private static let format = "org.tinfoilkit.household-backup"
    private static let version = 1
    private static let maximumBytes = 64 * 1_024 * 1_024

    static func encode(_ snapshot: HouseholdSnapshot) throws -> Data {
        guard snapshot.isValid else { throw BackupError.invalidHousehold }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Envelope(format: format, version: version, household: snapshot))
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        return data
    }

    static func importing(_ data: Data, as kind: Kind, into snapshot: HouseholdSnapshot) throws -> HouseholdSnapshot {
        guard data.count <= kind.maximumBytes else { throw BackupError.tooLarge }
        switch kind {
        case .desktopNotes:
            return try DesktopHouseholdFiles.applying(notes: data, to: snapshot)
        case .desktopPlaces:
            return try DesktopHouseholdFiles.applying(places: data, to: snapshot)
        case .native:
            let envelope: Envelope
            do {
                envelope = try JSONDecoder().decode(Envelope.self, from: data)
            } catch {
                throw BackupError.invalidFile
            }
            guard envelope.format == format else { throw BackupError.invalidFile }
            guard envelope.version == version else { throw BackupError.unsupportedVersion }
            guard envelope.household.isValid else { throw BackupError.invalidHousehold }
            return envelope.household
        }
    }

    static func importing(_ data: Data, asText: Bool, into snapshot: HouseholdSnapshot) throws -> HouseholdSnapshot {
        if asText { return try importing(data, as: .desktopNotes, into: snapshot) }
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        let probe: FormatProbe
        do {
            probe = try JSONDecoder().decode(FormatProbe.self, from: data)
        } catch {
            throw BackupError.invalidFile
        }
        return try importing(data, as: probe.hasFormat ? .native : .desktopPlaces, into: snapshot)
    }

    private struct Envelope: Codable {
        let format: String
        let version: Int
        let household: HouseholdSnapshot
    }

    private struct FormatProbe: Decodable {
        let hasFormat: Bool

        enum CodingKeys: String, CodingKey { case format }

        init(from decoder: any Decoder) throws {
            hasFormat = try decoder.container(keyedBy: CodingKeys.self).contains(.format)
        }
    }

    private enum BackupError: LocalizedError {
        case invalidFile, invalidHousehold, unsupportedVersion, tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidFile: "Choose a Tinfoil Kit household backup."
            case .invalidHousehold: "The household backup contains invalid or duplicate locations or supplies."
            case .unsupportedVersion: "This Tinfoil Kit household backup uses an unsupported version."
            case .tooLarge: "The household file is too large."
            }
        }
    }
}
