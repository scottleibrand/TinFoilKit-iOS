enum RegionalServiceCategory: String, CaseIterable, Identifiable, Sendable {
    case hospital, urgentCare = "urgent_care", pharmacy, police, fireStation = "fire_station"
    case shelter, gas, grocery, hardware, drinkingWater = "drinking_water"

    var id: String { rawValue }
}
