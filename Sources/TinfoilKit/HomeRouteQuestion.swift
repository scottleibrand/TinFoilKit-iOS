import Foundation

struct HomeRouteQuestion: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case walking, driving, choose
    }

    let mode: Mode
    let destination: String
    let rawDestination: String
    let allowsLibraryFallback: Bool

    static func parse(_ question: String) -> Self? {
        guard question.utf8.count <= 512 else { return nil }
        let text = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for prefix in prefixes {
            guard let span = text.range(of: prefix.text, options: [.anchored, .caseInsensitive], locale: locale) else {
                continue
            }
            let suffix = text[span.upperBound...]
            guard let end = suffix.lastIndex(where: { !" ?!.".contains($0) }) else { return nil }
            let raw = String(suffix[...end])
            // Leave compound questions with ordinary Ask.
            guard !raw.contains(where: { "?!;".contains($0) }),
                  raw.range(of: compoundClause, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
            let normalized = normalize(raw)
            guard !normalized.isEmpty else { return nil }
            return Self(mode: prefix.mode, destination: normalized, rawDestination: raw,
                        allowsLibraryFallback: prefix.allowsLibraryFallback)
        }
        return nil
    }

    func matchingPins(in names: [String]) -> [Int] {
        let normalized = names.map(Self.normalize)
        let exact = normalized.indices.filter { normalized[$0] == destination }
        guard exact.isEmpty, let prefix = ["my ", "our ", "the "].first(where: { destination.hasPrefix($0) }) else {
            return exact
        }
        let alias = destination.dropFirst(prefix.count)
        return normalized.indices.filter { normalized[$0] == alias }
    }

    func matchesName(_ name: String) -> Bool {
        Self.normalize(name) == destination
    }

    var isStreetAddress: Bool {
        let words = destination.split(separator: " ")
        return words.count >= 2 && words[0].first?.isNumber == true && words.dropFirst().contains {
            $0.contains(where: \.isLetter)
        }
    }

    func matchesAddress(_ address: String) -> Bool {
        let sought = Self.addressParts(destination)
        let actual = Self.addressParts(address)
        return isStreetAddress && sought.allSatisfy { !$0.isEmpty } && actual.starts(with: sought)
    }

    private static let locale = Locale(identifier: "en_US_POSIX")
    private static let prefixes: [(text: String, mode: Mode, allowsLibraryFallback: Bool)] = [
        ("walk from home to ", .walking, false),
        ("drive from home to ", .driving, false),
        ("how do i walk from home to ", .walking, false),
        ("how do i drive from home to ", .driving, false),
        ("directions from home to ", .choose, false),
        ("directions to ", .choose, false),
        ("how do i get to ", .choose, true)
    ]
    private static let compoundClause = #"(?:\.\s+|,\s+and\s+)(?:(?:is|are|can|could|do|does|will|would)\s+(?:i|we|it|you|they|there)|(?:tell|show)\s+me|(?:what|where|when|why|how)\s+(?:is|are|do|can|should))\b"#

    private static func addressParts(_ address: String) -> [String] {
        address.split(separator: ",", omittingEmptySubsequences: false).map { normalize(String($0)) }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?!."))
    }
}
