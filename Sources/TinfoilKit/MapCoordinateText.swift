import CoreLocation
import Foundation

enum MapCoordinateText {
    static func decimal(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"),
               coordinate.latitude, coordinate.longitude)
    }

    static func googleMapsURL(_ coordinate: CLLocationCoordinate2D) -> URL? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/maps/search/"
        components.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: decimal(coordinate).replacingOccurrences(of: " ", with: ""))
        ]
        return components.url
    }

    static func degreesMinutesSeconds(_ coordinate: CLLocationCoordinate2D) -> String {
        let latitude = sexagesimal(coordinate.latitude, positive: "N", negative: "S")
        let longitude = sexagesimal(coordinate.longitude, positive: "E", negative: "W")
        return "\(latitude), \(longitude)"
    }

    static func parse(_ text: String) -> CLLocationCoordinate2D? {
        guard text.utf8.count <= 200 else { return nil }
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
        if fields.count == 2,
           let latitude = Double(fields[0].trimmingCharacters(in: .whitespacesAndNewlines)),
           let longitude = Double(fields[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
            return valid(latitude: latitude, longitude: longitude)
        }

        if let match = captures(dms, in: text),
           let latitude = angle(in: text, match: match, group: 1),
           let longitude = angle(in: text, match: match, group: 5) {
            return valid(latitude: latitude, longitude: longitude)
        }
        if let match = captures(decimalSuffix, in: text) {
            return cardinalPair(in: text, match: match, directions: (2, 4), values: (1, 3))
        }
        if let match = captures(decimalPrefix, in: text) {
            return cardinalPair(in: text, match: match, directions: (1, 3), values: (2, 4))
        }
        if let match = captures(degreesMinutesPrefix, in: text) {
            guard let a = number(in: text, match: match, group: 3), a < 60,
                  let b = number(in: text, match: match, group: 6), b < 60 else { return nil }
            return cardinalPair(in: text, match: match, directions: (1, 4), values: (2, 5), minutes: (a, b))
        }
        return nil
    }

    private static let dms = try! NSRegularExpression(
        pattern: #"^\s*(\d{1,2})\s*°\s*(\d{1,2})\s*['′]\s*(\d{1,2}(?:\.\d+)?)\s*["″]?\s*([NS])\s*,?\s*(\d{1,3})\s*°\s*(\d{1,2})\s*['′]\s*(\d{1,2}(?:\.\d+)?)\s*["″]?\s*([EW])\s*$"#,
        options: .caseInsensitive
    )

    private static let decimalSuffix = try! NSRegularExpression(
        pattern: #"^\s*(\d{1,3}\.\d+)\s*°?\s*([NSEW])\s*,?\s*(\d{1,3}\.\d+)\s*°?\s*([NSEW])\s*$"#,
        options: .caseInsensitive
    )
    private static let decimalPrefix = try! NSRegularExpression(
        pattern: #"^\s*([NSEW])\s*(\d{1,3}\.\d+)\s*°?\s*,?\s*([NSEW])\s*(\d{1,3}\.\d+)\s*°?\s*$"#,
        options: .caseInsensitive
    )
    private static let degreesMinutesPrefix = try! NSRegularExpression(
        pattern: #"^\s*([NSEW])\s*(\d{1,3})\s*°\s*(\d{1,2}(?:\.\d+)?)\s*['′]\s*,?\s*([NSEW])\s*(\d{1,3})\s*°\s*(\d{1,2}(?:\.\d+)?)\s*['′]\s*$"#,
        options: .caseInsensitive
    )

    private static func captures(_ pattern: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func number(in text: String, match: NSTextCheckingResult, group: Int) -> Double? {
        Range(match.range(at: group), in: text).flatMap { Double(text[$0]) }
    }

    private static func cardinalPair(in text: String, match: NSTextCheckingResult, directions: (Int, Int),
                                     values: (Int, Int), minutes: (Double, Double) = (0, 0)) -> CLLocationCoordinate2D? {
        guard let first = Range(match.range(at: directions.0), in: text),
              let second = Range(match.range(at: directions.1), in: text),
              let a = number(in: text, match: match, group: values.0),
              let b = number(in: text, match: match, group: values.1) else { return nil }
        let axes = (text[first].uppercased(), text[second].uppercased())
        let firstLatitude = axes.0 == "N" || axes.0 == "S"
        let secondLatitude = axes.1 == "N" || axes.1 == "S"
        guard firstLatitude != secondLatitude else { return nil }
        let signedA = (axes.0 == "S" || axes.0 == "W" ? -1 : 1) * (a + minutes.0 / 60)
        let signedB = (axes.1 == "S" || axes.1 == "W" ? -1 : 1) * (b + minutes.1 / 60)
        return firstLatitude ? valid(latitude: signedA, longitude: signedB) : valid(latitude: signedB, longitude: signedA)
    }

    private static func valid(latitude: Double, longitude: Double) -> CLLocationCoordinate2D? {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    private static func angle(in text: String, match: NSTextCheckingResult, group: Int) -> Double? {
        let parts = (group..<(group + 4)).compactMap { Range(match.range(at: $0), in: text).map { text[$0] } }
        guard parts.count == 4, let degrees = Double(parts[0]), let minutes = Double(parts[1]),
              let seconds = Double(parts[2]), minutes < 60, seconds < 60 else { return nil }
        let positive = degrees + minutes / 60 + seconds / 3600
        return ["S", "W"].contains(parts[3].uppercased()) ? -positive : positive
    }

    private static func sexagesimal(_ angle: Double, positive: String, negative: String) -> String {
        let tenths = Int((abs(angle) * 36_000).rounded())
        let degrees = tenths / 36_000
        let minutes = tenths / 600 % 60
        let seconds = Double(tenths % 600) / 10
        let suffix = angle < 0 ? negative : positive
        return String(format: "%d°%02d′%04.1f″%@", locale: Locale(identifier: "en_US_POSIX"),
                      degrees, minutes, seconds, suffix)
    }
}
