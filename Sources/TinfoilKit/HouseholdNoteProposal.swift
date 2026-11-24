import Foundation

enum HouseholdNoteProposal {
    static let maximumBodyBytes = 8_192

    static func bodyLength(headers: [String: [String]]) -> Int? {
        // A browser must send the custom marker. An ordinary cross-site form can't add it.
        guard headers["x-tinfoil-guest-note"] == ["1"], headers["transfer-encoding"] == nil,
              let lengths = headers["content-length"], lengths.count == 1, let length = lengths.first,
              !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(length), (1...maximumBodyBytes).contains(count),
              let types = headers["content-type"], types.count == 1,
              types[0].split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
                == "application/x-www-form-urlencoded" else { return nil }
        return count
    }

    static func parse(_ body: Data) -> String? {
        guard body.count <= maximumBodyBytes, !body.contains(UInt8(ascii: "&")) else { return nil }
        let fields = body.split(separator: UInt8(ascii: "="), maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2, decode(fields[0]) == "note", let value = decode(fields[1]) else { return nil }

        let allowedControls: Set<Unicode.Scalar> = ["\r", "\n", "\t"]
        guard value.unicodeScalars.allSatisfy({
            $0.properties.generalCategory != .control || allowedControls.contains($0)
        }) else { return nil }

        let note = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty, note.count <= 1_000 else { return nil }
        return note
    }

    private static func decode(_ bytes: Data) -> String? {
        String(data: bytes, encoding: .utf8)?
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding
    }
}
