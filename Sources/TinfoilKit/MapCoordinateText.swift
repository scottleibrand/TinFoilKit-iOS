import CoreLocation
import Foundation

enum MapCoordinateText {
    static func decimal(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"),
               coordinate.latitude, coordinate.longitude)
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

        guard let match = dms.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let latitude = angle(in: text, match: match, group: 1),
              let longitude = angle(in: text, match: match, group: 5) else { return nil }
        return valid(latitude: latitude, longitude: longitude)
    }

    private static let dms = try! NSRegularExpression(
        pattern: #"^\s*(\d{1,2})\s*°\s*(\d{1,2})\s*['′]\s*(\d{1,2}(?:\.\d+)?)\s*["″]?\s*([NS])\s*,?\s*(\d{1,3})\s*°\s*(\d{1,2})\s*['′]\s*(\d{1,2}(?:\.\d+)?)\s*["″]?\s*([EW])\s*$"#,
        options: .caseInsensitive
    )

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
