import Foundation

enum NearbyServiceQuestion: String, CaseIterable, Sendable {
    case hospital, urgentCare = "urgent_care", pharmacy, police, fireStation = "fire_station"
    case shelter, gas, grocery, hardware, drinkingWater = "drinking_water"

    static func parseDirections(_ question: String) -> Self? {
        guard question.utf8.count <= 512 else { return nil }
        let text = question.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for prefix in ["how do i get to ", "directions to ", "directions from home to "] where text.hasPrefix(prefix) {
            let destination = text.dropFirst(prefix.count)
            guard ["the nearest ", "the closest ", "nearest ", "closest "].contains(where: {
                destination.hasPrefix($0)
            }) else { return nil }
            return parse(String(destination))
        }
        return nil
    }

    static func parse(_ question: String) -> Self? {
        guard question.utf8.count <= 512 else { return nil }
        let text = question.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let match = phrase.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range(at: 1).location != NSNotFound || match.range(at: 3).location != NSNotFound,
              let service = Range(match.range(at: 2), in: text) else { return nil }
        return services[String(text[service])]
    }

    // Match a whole request so another place, travel mode, or availability qualifier reaches ordinary Ask.
    private static let phrase = try! NSRegularExpression(
        pattern: #"\A(?:(?:where (?:is|are|can i find)|what (?:is|are)|(?:where|what)['’]s|find(?: me)?|show me) )?(?:(?:the|a|an|some) )?(?:(nearest|closest) )?([a-z][a-z -]*?)(?: ((?:to|near|around) (?:my |our |the )?(?:saved )?home))?[?!.]?\z"#
    )

    private static let services: [String: Self] = [
        "hospital": .hospital, "hospitals": .hospital,
        "urgent care": .urgentCare, "urgent care clinic": .urgentCare, "urgent care clinics": .urgentCare,
        "pharmacy": .pharmacy, "pharmacies": .pharmacy, "drugstore": .pharmacy, "drugstores": .pharmacy,
        "police station": .police, "police stations": .police,
        "fire station": .fireStation, "fire stations": .fireStation,
        "shelter": .shelter, "shelters": .shelter,
        "gas station": .gas, "gas stations": .gas, "fuel station": .gas, "fuel stations": .gas,
        "grocery store": .grocery, "grocery stores": .grocery, "supermarket": .grocery, "supermarkets": .grocery,
        "hardware store": .hardware, "hardware stores": .hardware,
        "drinking water": .drinkingWater, "drinking water source": .drinkingWater,
        "drinking water sources": .drinkingWater, "drinking water fountain": .drinkingWater,
        "drinking water fountains": .drinkingWater
    ]
}
