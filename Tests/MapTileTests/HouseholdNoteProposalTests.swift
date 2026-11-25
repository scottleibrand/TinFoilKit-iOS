import Foundation
import XCTest
@testable import TinfoilKit

final class HouseholdNoteProposalTests: XCTestCase {
    func testDecodesOneFieldAndPreservesInternalWhitespace() {
        XCTAssertEqual(
            parse("%6Eote=++Meet+at+caf%C3%A9%0D%0A%09Bring+A%2BB%26C%3D2+"),
            "Meet at café\r\n\tBring A+B&C=2"
        )
        XCTAssertEqual(parse("note=literal=equals"), "literal=equals")
        XCTAssertEqual(parse("note=%2526"), "%26")
    }

    func testRejectsUnexpectedAndMalformedFormData() {
        for body in [
            "", "note", "notes=hello", "note=", "note=+%0A%09",
            "note=hello&", "note=hello&note=there", "note=hello&%6Eote=there",
            "other=x&note=hello", "note=hello&other=x", "note=hello&\u{0301}",
            "note=%", "note=%G0", "note=%FF", "note=%C0%80"
        ] {
            XCTAssertNil(parse(body), body)
        }
        XCTAssertNil(HouseholdNoteProposal.parse(Data("note=".utf8) + Data([0xFF])))
    }

    func testRejectsControlCharactersBeforeTrimming() {
        for body in ["note=%00hello", "note=hello%1F", "note=%0Bhello", "note=hello%7F", "note=%C2%85hello"] {
            XCTAssertNil(parse(body), body)
        }
    }

    func testLimitsBodyBytesAndCountsGraphemeClusters() {
        let composedCharacter = "e\u{0301}"
        let note = String(repeating: composedCharacter, count: 1_000)
        XCTAssertEqual(parse("note=\(note)"), note)
        XCTAssertNil(parse("note=\(note)\(composedCharacter)"))
        XCTAssertEqual(parse("note=ok" + String(repeating: "+", count: 8_185)), "ok")
        XCTAssertNil(parse("note=ok" + String(repeating: "+", count: 8_186)))
    }

    func testRequiresMarkedFormWithOneBoundedContentLength() {
        let valid = [
            "x-tinfoil-guest-note": ["1"],
            "content-length": ["7"],
            "content-type": ["application/x-www-form-urlencoded; charset=UTF-8"]
        ]
        XCTAssertEqual(HouseholdNoteProposal.bodyLength(headers: valid), 7)
        for (name, values) in [
            ("x-tinfoil-guest-note", nil),
            ("x-tinfoil-guest-note", ["1", "1"]),
            ("content-length", ["7", "7"]),
            ("content-length", ["+7"]),
            ("content-length", ["8193"]),
            ("content-type", ["application/json"]),
            ("transfer-encoding", ["chunked"])
        ] as [(String, [String]?)] {
            var headers = valid
            headers[name] = values
            XCTAssertNil(HouseholdNoteProposal.bodyLength(headers: headers), name)
        }
    }

    private func parse(_ body: String) -> String? {
        HouseholdNoteProposal.parse(Data(body.utf8))
    }
}
