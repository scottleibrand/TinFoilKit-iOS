import Foundation

enum NWSForecastKind: String, CaseIterable, Codable, Sendable {
    case daily, hourly
}

enum NWSForecastError: LocalizedError, Equatable {
    case invalidResponse
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The National Weather Service forecast response could not be verified."
        case .responseTooLarge: "The National Weather Service forecast exceeded the download limit."
        }
    }
}

struct NWSForecastLocation: Equatable, Sendable {
    let coordinates: String

    init?(_ text: String) {
        guard text.utf8.count <= 96 else { return nil }
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let latitude = Double(fields[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let longitude = Double(fields[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let locale = Locale(identifier: "en_US_POSIX")
        let lat = Double(Int((latitude * 100).rounded())) / 100
        let lon = Double(Int((longitude * 100).rounded())) / 100
        coordinates = String(format: "%.2f,%.2f", locale: locale, lat, lon)
    }

    var endpoint: URL { URL(string: "https://api.weather.gov/points/\(coordinates)")! }
}

struct NWSForecastPoint: Codable, Equatable, Sendable {
    static let maxResponseBytes = 65_536

    let fetchedAt: Date
    let dailyURL: URL
    let hourlyURL: URL
    let timeZoneIdentifier: String?

    func url(for kind: NWSForecastKind) -> URL {
        switch kind {
        case .daily: dailyURL
        case .hourly: hourlyURL
        }
    }

    static func decode(_ data: Data, fetchedAt: Date) throws -> Self {
        guard data.count <= maxResponseBytes else { throw NWSForecastError.responseTooLarge }
        guard let response = try? JSONDecoder().decode(PointResponse.self, from: data),
              response.type == "Feature" else { throw NWSForecastError.invalidResponse }
        return try Self(fetchedAt: fetchedAt, dailyURL: response.properties.forecast,
                        hourlyURL: response.properties.forecastHourly, timeZoneIdentifier: response.properties.timeZone)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(fetchedAt: values.decode(Date.self, forKey: .fetchedAt),
                      dailyURL: values.decode(URL.self, forKey: .dailyURL),
                      hourlyURL: values.decode(URL.self, forKey: .hourlyURL),
                      timeZoneIdentifier: values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier))
    }

    private init(fetchedAt: Date, dailyURL: URL, hourlyURL: URL, timeZoneIdentifier: String?) throws {
        guard fetchedAt.timeIntervalSinceReferenceDate.isFinite,
              Self.isForecastGridURL(dailyURL),
              hourlyURL.absoluteString == dailyURL.absoluteString + "/hourly" else {
            throw NWSForecastError.invalidResponse
        }
        self.fetchedAt = fetchedAt
        self.dailyURL = dailyURL
        self.hourlyURL = hourlyURL
        self.timeZoneIdentifier = timeZoneIdentifier.flatMap { TimeZone(identifier: $0)?.identifier }
    }

    private static func isForecastGridURL(_ url: URL) -> Bool {
        guard url.absoluteString.hasPrefix("https://api.weather.gov/gridpoints/"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "api.weather.gov",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.path == components.percentEncodedPath else { return false }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 5, path[0].isEmpty, path[1] == "gridpoints", path[4] == "forecast",
              path[2].utf8.count == 3, path[2].utf8.allSatisfy({ (65...90).contains($0) }) else { return false }
        let coordinates = path[3].split(separator: ",", omittingEmptySubsequences: false)
        return coordinates.count == 2 && coordinates.allSatisfy {
            (1...4).contains($0.utf8.count) && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    private struct PointResponse: Decodable {
        struct Properties: Decodable {
            let forecast: URL
            let forecastHourly: URL
            let timeZone: String?
        }

        let type: String
        let properties: Properties
    }
}

struct NWSForecastPeriod: Identifiable, Codable, Equatable, Sendable {
    let id: Int
    let name: String
    let start: Date
    let end: Date
    let shortForecast: String
    let detailedForecast: String?
    let temperature: Int
    let temperatureUnit: String
}

struct NWSForecastSnapshot: Codable, Equatable, Sendable {
    static let maxResponseBytes = 512 * 1024
    private static let maximumPeriods = 256

    let kind: NWSForecastKind
    let checkedAt: Date
    let sourceUpdatedAt: Date
    let expiresAt: Date?
    let etag: String?
    let lastModified: String?
    let periods: [NWSForecastPeriod]

    static func decode(_ data: Data, kind: NWSForecastKind, checkedAt: Date, expiresAt: Date?,
                       etag: String?, lastModified: String?) throws -> Self {
        guard data.count <= maxResponseBytes else { throw NWSForecastError.responseTooLarge }
        guard let response = try? JSONDecoder().decode(ForecastResponse.self, from: data),
              response.type == "Feature" else { throw NWSForecastError.invalidResponse }
        let properties = response.properties
        guard properties.periods.count <= maximumPeriods else { throw NWSForecastError.responseTooLarge }
        let timestamps = ForecastTimestamps()
        guard let sourceUpdatedAt = timestamps.parse(properties.updateTime) else { throw NWSForecastError.invalidResponse }
        let periods = try properties.periods.map { period in
            guard let start = timestamps.parse(period.startTime),
                  let end = timestamps.parse(period.endTime) else { throw NWSForecastError.invalidResponse }
            let detailed = period.detailedForecast?.trimmingCharacters(in: .whitespacesAndNewlines)
            return NWSForecastPeriod(id: period.number, name: period.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                     start: start, end: end,
                                     shortForecast: period.shortForecast.trimmingCharacters(in: .whitespacesAndNewlines),
                                     detailedForecast: detailed?.isEmpty == false ? detailed : nil,
                                     temperature: period.temperature, temperatureUnit: period.temperatureUnit)
        }
        try validate(kind: kind, checkedAt: checkedAt, sourceUpdatedAt: sourceUpdatedAt,
                     expiresAt: expiresAt, periods: periods)
        return Self(kind: kind, checkedAt: checkedAt, sourceUpdatedAt: sourceUpdatedAt, expiresAt: expiresAt,
                    etag: etag, lastModified: lastModified, periods: periods)
    }

    func revalidated(at checkedAt: Date, expiresAt: Date?, etag: String?, lastModified: String?) -> Self {
        Self(kind: kind, checkedAt: checkedAt, sourceUpdatedAt: sourceUpdatedAt,
             expiresAt: expiresAt ?? self.expiresAt, etag: Self.header(etag) ?? self.etag,
             lastModified: Self.header(lastModified) ?? self.lastModified, periods: periods)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(NWSForecastKind.self, forKey: .kind)
        let checkedAt = try values.decode(Date.self, forKey: .checkedAt)
        let sourceUpdatedAt = try values.decode(Date.self, forKey: .sourceUpdatedAt)
        let expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        let periods = try values.decode([NWSForecastPeriod].self, forKey: .periods)
        try Self.validate(kind: kind, checkedAt: checkedAt, sourceUpdatedAt: sourceUpdatedAt,
                          expiresAt: expiresAt, periods: periods)
        self.init(kind: kind, checkedAt: checkedAt, sourceUpdatedAt: sourceUpdatedAt, expiresAt: expiresAt,
                  etag: try values.decodeIfPresent(String.self, forKey: .etag),
                  lastModified: try values.decodeIfPresent(String.self, forKey: .lastModified), periods: periods)
    }

    private init(kind: NWSForecastKind, checkedAt: Date, sourceUpdatedAt: Date, expiresAt: Date?,
                 etag: String?, lastModified: String?, periods: [NWSForecastPeriod]) {
        self.kind = kind
        self.checkedAt = checkedAt
        self.sourceUpdatedAt = sourceUpdatedAt
        self.expiresAt = expiresAt
        self.etag = Self.header(etag)
        self.lastModified = Self.header(lastModified)
        self.periods = periods
    }

    private static func validate(kind: NWSForecastKind, checkedAt: Date, sourceUpdatedAt: Date, expiresAt: Date?,
                                 periods: [NWSForecastPeriod]) throws {
        guard periods.count <= maximumPeriods else { throw NWSForecastError.responseTooLarge }
        guard !periods.isEmpty, checkedAt.timeIntervalSinceReferenceDate.isFinite,
              sourceUpdatedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw NWSForecastError.invalidResponse
        }
        var ids = Set<Int>()
        var previousEnd: Date?
        for period in periods {
            guard period.id > 0, ids.insert(period.id).inserted, period.start < period.end,
                  previousEnd.map({ $0 <= period.start }) ?? true,
                  period.start.timeIntervalSinceReferenceDate.isFinite,
                  period.end.timeIntervalSinceReferenceDate.isFinite,
                  (kind == .hourly || !period.name.isEmpty), period.name.utf8.count <= 256,
                  !period.shortForecast.isEmpty, period.shortForecast.utf8.count <= 1_024,
                  (period.detailedForecast?.utf8.count ?? 0) <= 8_192,
                  period.temperatureUnit == "F" || period.temperatureUnit == "C" else {
                throw NWSForecastError.invalidResponse
            }
            previousEnd = period.end
        }
    }

    private static func header(_ value: String?) -> String? {
        guard let value, (1...1_024).contains(value.utf8.count),
              value.utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return value
    }

    private struct ForecastTimestamps {
        let standard = ISO8601DateFormatter()
        let fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        func parse(_ input: String) -> Date? {
            guard input.utf8.count <= 64 else { return nil }
            return standard.date(from: input) ?? fractional.date(from: input)
        }
    }

    private struct ForecastResponse: Decodable {
        struct Properties: Decodable {
            struct Period: Decodable {
                let number: Int
                let name: String
                let startTime: String
                let endTime: String
                let shortForecast: String
                let detailedForecast: String?
                let temperature: Int
                let temperatureUnit: String
            }

            let updateTime: String
            let periods: [Period]
        }

        let type: String
        let properties: Properties
    }
}
