import Foundation

struct HouseholdResource: Codable, Equatable, Identifiable, Sendable {
    static let maximumNameLength = 80

    var id = UUID()
    var name: String
    var category: Category
    var quantity: Double?
    var quantityUnit: Unit
    var dailyUse: Double?
    var dailyUseUnit: Unit

    enum Category: String, CaseIterable, Codable, Identifiable, Sendable {
        case water, food, fuel, electricity, medication

        var id: Self { self }

        var title: String {
            switch self {
            case .water: "Water"
            case .food: "Food"
            case .fuel: "Fuel"
            case .electricity: "Electricity"
            case .medication: "Medication"
            }
        }

        var units: [Unit] {
            switch self {
            case .water, .fuel: [.gallons, .liters]
            case .food: [.meals, .kilocalories]
            case .electricity: [.wattHours, .kilowattHours]
            case .medication: [.doses]
            }
        }
    }

    enum Unit: String, Codable, Identifiable, Sendable {
        case gallons, liters, meals, kilocalories, wattHours, kilowattHours, doses

        var id: Self { self }

        var title: String {
            switch self {
            case .gallons: "US gallons"
            case .liters: "Liters"
            case .meals: "Meals"
            case .kilocalories: "Kilocalories (kcal)"
            case .wattHours: "Watt-hours (Wh)"
            case .kilowattHours: "Kilowatt-hours (kWh)"
            case .doses: "Doses"
            }
        }

        private enum Dimension: Equatable {
            case volume, meals, nutritionEnergy, electricity, doses
        }

        private var scale: (dimension: Dimension, factor: Double) {
            switch self {
            case .gallons: (.volume, 3.785_411_784)
            case .liters: (.volume, 1)
            case .meals: (.meals, 1)
            case .kilocalories: (.nutritionEnergy, 1)
            case .wattHours: (.electricity, 1)
            case .kilowattHours: (.electricity, 1_000)
            case .doses: (.doses, 1)
            }
        }

        fileprivate func multiplier(to unit: Self) -> Double? {
            let (dimension, factor) = scale
            let target = unit.scale
            guard dimension == target.dimension else { return nil }
            return factor / target.factor
        }
    }

    var isValid: Bool {
        name.utf8.count <= Self.maximumNameLength * 4 && name.count <= Self.maximumNameLength
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.unicodeScalars.allSatisfy({
                $0.properties.generalCategory != .control && !CharacterSet.newlines.contains($0)
            })
            && category.units.contains(quantityUnit) && category.units.contains(dailyUseUnit)
            && (quantity.map { $0.isFinite && $0 >= 0 } ?? true)
            && (dailyUse.map { $0.isFinite && $0 >= 0 } ?? true)
    }

    var estimatedDays: Double? {
        guard isValid, let quantity else { return nil }
        if quantity == 0 { return 0 }
        guard let dailyUse, dailyUse > 0, let multiplier = quantityUnit.multiplier(to: dailyUseUnit) else { return nil }
        let days = (quantity / dailyUse) * multiplier
        if days.isFinite, days > 0 { return days }
        // Scaling first can preserve a representable estimate when the initial division overflows or underflows.
        let scaledDays = (quantity * multiplier) / dailyUse
        return scaledDays.isFinite && scaledDays > 0 ? scaledDays : nil
    }

    static func shortest(in resources: [Self]) -> Self? {
        var shortest: Self?
        var minimum = Double.infinity
        for resource in resources {
            if let days = resource.estimatedDays, days < minimum {
                shortest = resource
                minimum = days
            }
        }
        return shortest
    }

    static func parseAmount(_ input: String, locale: Locale) -> Double? {
        let separator = locale.decimalSeparator ?? "."
        if separator != ".", input.contains(".") { return nil }
        let text = input.replacingOccurrences(of: separator, with: ".")
        var normalized = ""
        for character in text {
            if let value = character.wholeNumberValue, character.unicodeScalars.count == 1,
               character.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains) {
                normalized.append(String(value))
            } else if ".+-eE".contains(character) {
                normalized.append(character)
            } else {
                return nil
            }
        }
        guard let value = Double(normalized), value.isFinite, value >= 0 else { return nil }
        // Reject a nonzero entry that underflows to zero, which would look like a stockout.
        let mantissa = normalized.prefix { $0 != "e" && $0 != "E" }
        guard value > 0 || !mantissa.contains(where: { "123456789".contains($0) }) else { return nil }
        return value
    }

    static func formatDays(_ days: Double) -> String {
        guard days.isFinite, days >= 0 else { return "Unknown" }
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        if days > 0, days < 0.1 {
            return "<\(0.1.formatted(style)) days"
        }
        let number = (days == 0 ? 0 : days).formatted(style)
        return number == 1.0.formatted(style) ? "\(number) day" : "\(number) days"
    }
}
