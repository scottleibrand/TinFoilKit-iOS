import Foundation

enum HouseholdGuestProposal: Sendable {
    case note(String)
    case pin(HouseholdPlace)

    enum Kind: String {
        case note, pin

        var marker: String { "x-tinfoil-guest-\(rawValue)" }

        static func permitted(headers: [String: [String]], acceptsNotes: Bool, acceptsPins: Bool) -> Self? {
            let hasNoteMarker = headers[Self.note.marker] != nil
            let hasPinMarker = headers[Self.pin.marker] != nil
            if acceptsNotes, hasNoteMarker, !hasPinMarker { return .note }
            if acceptsPins, hasPinMarker, !hasNoteMarker { return .pin }
            return nil
        }

        func parse(_ body: Data) -> HouseholdGuestProposal? {
            switch self {
            case .note: HouseholdNoteProposal.parse(body).map(HouseholdGuestProposal.note)
            case .pin: HouseholdPinProposal.parse(body).map(HouseholdGuestProposal.pin)
            }
        }
    }
}

enum HouseholdPinProposal {
    static func parse(_ body: Data) -> HouseholdPlace? {
        guard body.count <= HouseholdNoteProposal.maximumBodyBytes else { return nil }
        var fields: [String: String] = [:]
        for field in body.split(separator: UInt8(ascii: "&"), omittingEmptySubsequences: false) {
            let pair = field.split(separator: UInt8(ascii: "="), maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let key = HouseholdNoteProposal.decode(pair[0]),
                  ["name", "coordinates", "note"].contains(key), fields[key] == nil,
                  let value = HouseholdNoteProposal.decode(pair[1]) else { return nil }
            fields[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = fields["name"], !name.isEmpty, name.count <= 80,
              validText(name, allowing: []), let text = fields["coordinates"],
              let coordinate = MapCoordinateText.parse(text) else { return nil }
        let note = fields["note"] ?? ""
        guard note.count <= 500, validText(note, allowing: ["\r", "\n", "\t"]) else { return nil }
        return HouseholdPlace(name: name, note: note, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private static func validText(_ text: String, allowing controls: Set<Unicode.Scalar>) -> Bool {
        text.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control || controls.contains($0) }
    }
}
