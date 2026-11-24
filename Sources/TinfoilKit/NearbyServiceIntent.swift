import Foundation

struct NearbyServiceIntent: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case find
        case directions
    }

    enum Origin: Equatable, Sendable {
        case unspecified
        case home
        case currentLocation
    }

    let category: RegionalServiceCategory
    let action: Action
    let origin: Origin

    static func parse(_ question: String) -> Self? {
        let text = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?!."))
        guard !text.isEmpty else { return nil }

        let action: Action
        var service: Substring
        if let prefix = directionPrefixes.first(where: { text.hasPrefix($0) }) {
            action = .directions
            service = text.dropFirst(prefix.count)
        } else if let prefix = findPrefixes.first(where: { text.hasPrefix($0) }) {
            action = .find
            service = text.dropFirst(prefix.count)
        } else {
            action = .find
            service = text[...]
        }

        // Require a proximity qualifier and a complete category phrase. Extra words can
        // specify a different origin, service, or condition that a regional index cannot infer.
        service = droppingFirstMatch(["the ", "a ", "an "], from: service)
        let qualifiedService = droppingFirstMatch(["nearest ", "closest ", "nearby "], from: service)
        var hasProximity = qualifiedService != service
        service = qualifiedService

        let origin: Origin
        if service.hasSuffix(" near me") || service.hasSuffix(" to me") {
            let suffix = service.hasSuffix(" near me") ? " near me" : " to me"
            origin = .currentLocation
            hasProximity = hasProximity || suffix == " near me"
            service = service.dropLast(suffix.count)
        } else if let suffix = [" near home", " to home", " from home"].first(where: { service.hasSuffix($0) }) {
            origin = .home
            hasProximity = hasProximity || suffix == " near home"
            service = service.dropLast(suffix.count)
        } else {
            origin = .unspecified
        }

        if service.hasSuffix(" nearby") {
            hasProximity = true
            service = service.dropLast(" nearby".count)
        }
        guard hasProximity, let category = categories[String(service)] else { return nil }
        return Self(category: category, action: action, origin: origin)
    }

    private static func droppingFirstMatch(_ prefixes: [String], from text: Substring) -> Substring {
        guard let prefix = prefixes.first(where: { text.hasPrefix($0) }) else { return text }
        return text.dropFirst(prefix.count)
    }

    private static let directionPrefixes = ["how do i get to ", "directions to "]
    private static let findPrefixes = ["where is ", "where's ", "where are ", "where can i find ", "find ", "show me "]

    private static let categories: [String: RegionalServiceCategory] = [
        "hospital": .hospital, "hospitals": .hospital,
        "urgent care": .urgentCare, "urgent care clinic": .urgentCare, "urgent care clinics": .urgentCare,
        "pharmacy": .pharmacy, "pharmacies": .pharmacy,
        "police station": .police, "police stations": .police,
        "fire station": .fireStation, "fire stations": .fireStation,
        "shelter": .shelter, "shelters": .shelter,
        "gas station": .gas, "gas stations": .gas, "fuel station": .gas, "fuel stations": .gas,
        "grocery store": .grocery, "grocery stores": .grocery, "supermarket": .grocery, "supermarkets": .grocery,
        "hardware store": .hardware, "hardware stores": .hardware,
        "drinking water": .drinkingWater, "drinking water fountain": .drinkingWater,
        "drinking water fountains": .drinkingWater
    ]
}
