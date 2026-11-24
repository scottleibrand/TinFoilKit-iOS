import Foundation

struct SavedPinRouteQuestion: Equatable {
    enum Mode: Equatable {
        case walking, driving
    }

    let mode: Mode
    let destination: String

    static func parse(_ question: String) -> Self? {
        guard question.utf8.count <= 512 else { return nil }
        let text = normalize(question)
        for (prefix, mode) in [("walk from home to ", Mode.walking), ("drive from home to ", .driving)]
            where text.hasPrefix(prefix) {
            let destination = String(text.dropFirst(prefix.count))
            // Leave compound questions with ordinary Ask.
            guard !destination.contains("?"), !destination.contains("!") else { return nil }
            return Self(mode: mode, destination: destination)
        }
        return nil
    }

    func matchingPins(in names: [String]) -> [Int] {
        names.indices.filter { Self.normalize(names[$0]) == destination }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?!."))
    }
}
