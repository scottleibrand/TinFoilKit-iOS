import Foundation

/// Scopes drinking-water outage questions to a named utility or service area.
struct WaterOutageContext: Sendable {
    let serviceArea: String?

    init?(question: String, serviceArea: String = "") {
        guard LibraryPassages.SearchIntent(question).isWaterServiceOutage else { return nil }
        let entered = String(serviceArea.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.serviceArea = Self.namedArea(in: question) ?? (entered.isEmpty ? nil : entered)
    }

    func searchQuestion(_ question: String) -> String {
        guard let serviceArea else { return question }
        return "\(serviceArea) \(question)"
    }

    var scopedQueries: [String] {
        guard let serviceArea else { return [] }
        let area = Self.words(serviceArea).prefix(6).joined(separator: " ")
        guard !area.isEmpty else { return [] }
        return ["\(area) water power", "\(area) water generator", "\(area) water outage"]
    }

    func relates(_ excerpt: String, title: String) -> Bool {
        guard let serviceArea else { return false }
        let area = Self.words(serviceArea).joined(separator: " ")
        guard !area.isEmpty else { return false }
        return [title, excerpt].contains { value in
            let text = Self.words(value).joined(separator: " ")
            return " \(text) ".contains(" \(area) ")
        }
    }

    func supportedQuote(in excerpt: String, title: String) -> String? {
        let lines = excerpt.replacingOccurrences(of: #"(?<=[.!?])\s+"#, with: "\n", options: .regularExpression)
        return lines.split(whereSeparator: \.isNewline).map(String.init).first { candidate in
            let text = candidate.lowercased()
            guard relates(candidate, title: title), candidate.count <= 360,
                  text.contains("power outage") || text.contains("without power") || text.contains("power failure"),
                  text.contains("water") || text.contains("pump") || text.contains("reservoir"),
                  text.range(of: #"\b(?:for|up to|at least)\s+\d+(?:\.\d+)?\s*(?:minutes?|hours?|days?)\b"#,
                             options: .regularExpression) != nil else {
                return false
            }
            return text.range(of: #"\b(?:continu\w*|operat\w*|maintain\w*|provid\w*|sustain\w*|runs?|running)\b"#,
                              options: .regularExpression) != nil
        }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func namedArea(in question: String) -> String? {
        let pattern = /(?i)^\s*(?:(?:how long|how many (?:hours|days))\s+(?:will|does|can|would)\s+)?([\p{L}\p{N}][\p{L}\p{N} .-]{0,79})[’']s\s+water\b/
        guard let name = question.firstMatch(of: pattern)?.output.1.trimmingCharacters(in: .whitespaces),
              !["my", "our", "the", "your", "this", "that"].contains(Self.words(name).first ?? "") else { return nil }
        return name
    }

    private static func words(_ value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
