import Foundation
import XCTest
@testable import TinfoilKit

final class HouseholdResourceTests: XCTestCase {
    func testConvertsLiquidVolumesAndElectricityInBothDirections() throws {
        var resource = HouseholdResource(name: "Drinking water", category: .water, quantity: 2,
                                         quantityUnit: .gallons, dailyUse: 1, dailyUseUnit: .liters)
        XCTAssertEqual(try XCTUnwrap(resource.estimatedDays), 7.570823568, accuracy: 0.000_000_001)
        resource.category = .fuel
        resource.quantity = 7.570823568
        resource.quantityUnit = .liters
        resource.dailyUseUnit = .gallons
        XCTAssertEqual(try XCTUnwrap(resource.estimatedDays), 2, accuracy: 0.000_000_001)

        resource = HouseholdResource(name: "Battery", category: .electricity, quantity: 2,
                                     quantityUnit: .kilowattHours, dailyUse: 500, dailyUseUnit: .wattHours)
        XCTAssertEqual(try XCTUnwrap(resource.estimatedDays), 4, accuracy: 0.000_000_001)
        resource.quantity = 2_000
        resource.quantityUnit = .wattHours
        resource.dailyUse = 0.5
        resource.dailyUseUnit = .kilowattHours
        XCTAssertEqual(try XCTUnwrap(resource.estimatedDays), 4, accuracy: 0.000_000_001)
    }

    func testFoodUnitsAreDistinctDimensions() {
        var resource = HouseholdResource(name: "Pantry", category: .food, quantity: 12,
                                         quantityUnit: .meals, dailyUse: 3, dailyUseUnit: .meals)
        XCTAssertEqual(resource.estimatedDays, 4)
        resource.dailyUseUnit = .kilocalories
        XCTAssertTrue(resource.isValid)
        XCTAssertNil(resource.estimatedDays)
        resource.quantity = 6_000
        resource.quantityUnit = .kilocalories
        resource.dailyUse = 2_000
        XCTAssertEqual(resource.estimatedDays, 3)
    }

    func testBlankZeroAndInvalidValues() {
        var resource = HouseholdResource(name: "Medication", category: .medication, quantity: nil,
                                         quantityUnit: .doses, dailyUse: nil, dailyUseUnit: .doses)
        XCTAssertTrue(resource.isValid)
        XCTAssertNil(resource.estimatedDays)
        resource.quantity = 2
        XCTAssertNil(resource.estimatedDays)
        resource.dailyUse = 0
        XCTAssertTrue(resource.isValid)
        XCTAssertNil(resource.estimatedDays)
        resource.quantity = 0
        XCTAssertEqual(resource.estimatedDays, 0)
        resource.dailyUse = nil
        XCTAssertEqual(resource.estimatedDays, 0)
        resource.dailyUse = 1
        XCTAssertEqual(resource.estimatedDays, 0)

        resource.dailyUse = -Double.infinity
        XCTAssertFalse(resource.isValid)
        XCTAssertNil(resource.estimatedDays)
        resource.dailyUse = 1
        for value in [-1, Double.nan, Double.infinity] {
            resource.quantity = value
            XCTAssertFalse(resource.isValid)
            XCTAssertNil(resource.estimatedDays)
        }
        resource.quantity = 2
        resource.dailyUseUnit = .liters
        XCTAssertFalse(resource.isValid)
        XCTAssertNil(resource.estimatedDays)
    }

    func testNameLimitAndNonfiniteEstimate() {
        var resource = HouseholdResource(name: " \n", category: .water, quantity: .greatestFiniteMagnitude,
                                         quantityUnit: .gallons, dailyUse: 0.1, dailyUseUnit: .liters)
        XCTAssertFalse(resource.isValid)
        resource.name = String(repeating: "a", count: HouseholdResource.maximumNameLength + 1)
        XCTAssertFalse(resource.isValid)
        for name in ["Drinking\nwater", "Drinking\u{2028}water", "Drinking\u{0000}water"] {
            resource.name = name
            XCTAssertFalse(resource.isValid)
        }
        resource.name = " Water "
        XCTAssertTrue(resource.isValid)
        XCTAssertNil(resource.estimatedDays)
    }

    func testConversionCanRescueIntermediateOverflowAndUnderflow() throws {
        var resource = HouseholdResource(name: "Battery", category: .electricity,
                                         quantity: .greatestFiniteMagnitude, quantityUnit: .wattHours,
                                         dailyUse: 0.5, dailyUseUnit: .kilowattHours)
        XCTAssertEqual(try XCTUnwrap(resource.estimatedDays), Double.greatestFiniteMagnitude * 0.002)
        resource.quantity = .leastNonzeroMagnitude
        resource.quantityUnit = .kilowattHours
        resource.dailyUse = 10
        resource.dailyUseUnit = .wattHours
        XCTAssertEqual(try XCTUnwrap(resource.estimatedDays), Double.leastNonzeroMagnitude * 100)
    }

    func testShortestSkipsUnknownAndKeepsFirstTie() {
        let unknown = HouseholdResource(name: "Fuel", category: .fuel, quantity: 1,
                                        quantityUnit: .liters, dailyUse: nil, dailyUseUnit: .liters)
        let longer = HouseholdResource(name: "Food", category: .food, quantity: 9,
                                       quantityUnit: .meals, dailyUse: 3, dailyUseUnit: .meals)
        let first = HouseholdResource(name: "Water", category: .water, quantity: 2,
                                      quantityUnit: .liters, dailyUse: 2, dailyUseUnit: .liters)
        var second = HouseholdResource(name: "Doses", category: .medication, quantity: 1,
                                       quantityUnit: .doses, dailyUse: 1, dailyUseUnit: .doses)
        XCTAssertNil(HouseholdResource.shortest(in: [unknown]))
        XCTAssertEqual(HouseholdResource.shortest(in: [unknown, longer, first, second])?.id, first.id)
        second.quantity = 0
        XCTAssertEqual(HouseholdResource.shortest(in: [first, second])?.id, second.id)
    }

    func testDaysFormattingHandlesRoundingAndSmallValues() {
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        XCTAssertEqual(HouseholdResource.formatDays(0), "\(0.0.formatted(style)) days")
        XCTAssertEqual(HouseholdResource.formatDays(1.04), "\(1.0.formatted(style)) day")
        XCTAssertEqual(HouseholdResource.formatDays(0.025), "<\(0.1.formatted(style)) days")
        XCTAssertEqual(HouseholdResource.formatDays(2.75), "\(2.8.formatted(style)) days")
        XCTAssertEqual(HouseholdResource.formatDays(.infinity), "Unknown")
    }

    func testLocalizedAmountsConsumeTheEntireInput() {
        let english = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")
        let arabic = Locale(identifier: "ar")
        XCTAssertEqual(HouseholdResource.parseAmount("1.25", locale: english), 1.25)
        XCTAssertEqual(HouseholdResource.parseAmount("1,25", locale: german), 1.25)
        XCTAssertEqual(HouseholdResource.parseAmount("١٢\(arabic.decimalSeparator ?? ".")٥", locale: arabic), 12.5)
        XCTAssertEqual(HouseholdResource.parseAmount("1,25e-100", locale: german), 1.25e-100)
        XCTAssertEqual(HouseholdResource.parseAmount("0", locale: german), 0)
        for invalid in ["", "12abc", "1.2.3", "0x1p0", "-1", "nan", "1e400", "1e-400"] {
            XCTAssertNil(HouseholdResource.parseAmount(invalid, locale: english), invalid)
        }
        XCTAssertNil(HouseholdResource.parseAmount("1.000", locale: german))
    }
}
