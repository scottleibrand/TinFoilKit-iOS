@main
struct VerifyNearbyServiceIntent {
    static func main() {
        let lookups: [(String, RegionalServiceCategory, NearbyServiceIntent.Origin)] = [
            ("Where is the closest gas station?", .gas, .unspecified),
            ("WHERE’S the\n nearest pharmacy?", .pharmacy, .unspecified),
            ("nearby urgent care clinic", .urgentCare, .unspecified),
            ("Find a police station near home", .police, .home),
            ("Where are fire stations near me?", .fireStation, .currentLocation),
            ("Where can I find a shelter nearby?", .shelter, .unspecified),
            ("Closest grocery store to home", .grocery, .home),
            ("Show me the nearest hardware store to me", .hardware, .currentLocation),
            ("Where can I find drinking water near home?", .drinkingWater, .home),
            ("Where is the nearest hospital?", .hospital, .unspecified)
        ]
        for (question, category, origin) in lookups {
            check(question, equals: NearbyServiceIntent(category: category, action: .find, origin: origin))
        }

        check("How do I get to the nearest hospital?",
              equals: NearbyServiceIntent(category: .hospital, action: .directions, origin: .unspecified))
        check("Directions to the closest pharmacy from home",
              equals: NearbyServiceIntent(category: .pharmacy, action: .directions, origin: .home))

        let libraryQuestions = [
            "",
            "pharmacy",
            "Where can I find a pharmacy?",
            "Is the nearest hospital open?",
            "Which is the closest gas station in Seattle?",
            "Find a pharmacy near my hotel",
            "Nearest grocery store with a generator",
            "Directions from home to 350 Fifth Avenue, New York",
            "Directions to the nearest pet shelter",
            "Nearby pharmacies and hospitals",
            "Does my local water system work during an outage?",
            "Where can I find safe drinking water after an earthquake?"
        ]
        for question in libraryQuestions {
            check(question, equals: nil)
        }
        print("Passed \(lookups.count + 2 + libraryQuestions.count) nearby service intent checks")
    }

    private static func check(_ question: String, equals expected: NearbyServiceIntent?) {
        let actual = NearbyServiceIntent.parse(question)
        precondition(actual == expected, "\(question.debugDescription) produced \(String(describing: actual))")
    }
}
