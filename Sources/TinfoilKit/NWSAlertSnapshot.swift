import Foundation

struct NWSAlert: Identifiable, Codable, Sendable {
    let id: String
    let event: String
    let headline: String?
    let areaDescription: String
    let description: String
    let instruction: String?
    let sent: Date
    let expires: Date

    var sourceURL: URL? { alertRecordURL(id) }
}

struct NWSAlertChange: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case update
        case cancellation
    }

    let id: String
    let kind: Kind
    let affectedIDs: [String]
    let sent: Date
    let event: String
    let headline: String?
    let areaDescription: String

    var sourceURL: URL? { alertRecordURL(id) }
}

struct NWSAlertSnapshot: Codable, Sendable {
    static let maximumResponseBytes = 2 * 1024 * 1024

    let area: String
    let checkedAt: Date
    let sourceUpdatedAt: Date?
    let etag: String?
    let lastModified: String?
    let alerts: [NWSAlert]

    private let reportedChanges: [NWSAlertChange]?
    var changes: [NWSAlertChange] { reportedChanges ?? [] }

    private enum CodingKeys: String, CodingKey {
        case area, checkedAt, sourceUpdatedAt, etag, lastModified, alerts
        case reportedChanges = "changes"
    }

    static func endpoint(for area: String) -> URL? {
        guard area.utf8.count == 2, area.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return URL(string: "https://api.weather.gov/alerts/active?area=\(area)&status=actual")
    }

    func revalidated(at date: Date, etag: String?, lastModified: String?) -> Self {
        Self(area: area, checkedAt: date, sourceUpdatedAt: sourceUpdatedAt, etag: etag ?? self.etag,
             lastModified: lastModified ?? self.lastModified, alerts: alerts, reportedChanges: reportedChanges)
    }

    static func decode(_ data: Data, area: String, checkedAt: Date, etag: String?, lastModified: String?) throws -> Self {
        guard data.count <= maximumResponseBytes else { throw NWSAlertError.responseTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let collection = try decoder.decode(Collection.self, from: data)
        guard endpoint(for: area) != nil, checkedAt.timeIntervalSinceReferenceDate.isFinite,
              collection.type == "FeatureCollection", collection.pagination?.next == nil else {
            throw NWSAlertError.invalidResponse
        }
        let timestamps = CAPTimestamps()
        let actual = collection.features.filter { $0.properties.status == "Actual" }
        var alerts: [String: NWSAlert] = [:]
        for feature in actual {
            let value = feature.properties
            guard value.messageType == "Alert" || value.messageType == "Update" else { continue }
            guard !feature.id.isEmpty, let event = value.event, !event.isEmpty,
                  let areaDescription = value.areaDesc, let description = value.description,
                  let sent = timestamps.parse(value.sent), let expires = timestamps.parse(value.expires),
                  expires >= sent else {
                throw NWSAlertError.invalidResponse
            }
            if let previous = alerts[feature.id], previous.sent >= sent { continue }
            alerts[feature.id] = NWSAlert(id: feature.id, event: event, headline: value.headline,
                                         areaDescription: areaDescription, description: description,
                                         instruction: value.instruction, sent: sent, expires: expires)
        }

        var changes: [String: NWSAlertChange] = [:]
        for feature in actual {
            guard let change = feature.change(area: area, checkedAt: checkedAt, alerts: alerts, timestamps: timestamps),
                  changes[change.id].map({ $0.sent < change.sent }) ?? true else { continue }
            changes[change.id] = change
        }
        for change in changes.values {
            for affectedID in change.affectedIDs { alerts.removeValue(forKey: affectedID) }
        }
        return Self(area: area, checkedAt: checkedAt, sourceUpdatedAt: collection.updated, etag: etag, lastModified: lastModified,
                    alerts: alerts.values.sorted { ($0.sent, $0.id) > ($1.sent, $1.id) },
                    reportedChanges: changes.values.sorted { ($0.sent, $0.id) > ($1.sent, $1.id) })
    }

    private struct Collection: Decodable {
        struct Pagination: Decodable { let next: String? }
        let type: String
        let updated: Date?
        let features: [Feature]
        let pagination: Pagination?
    }

    private struct Feature: Decodable {
        struct Properties: Decodable {
            struct Reference: Decodable {
                let url: String?
                let identifier: String?
                let sender: String?
                let sent: String?

                enum CodingKeys: String, CodingKey {
                    case url = "@id"
                    case identifier, sender, sent
                }
            }

            let id: String?
            let status: String
            let messageType: String
            let scope: String?
            let event: String?
            let headline: String?
            let areaDesc: String?
            let description: String?
            let instruction: String?
            let sent: String?
            let expires: String?
            let references: [Reference]?
        }

        let id: String
        let properties: Properties

        func change(area: String, checkedAt: Date, alerts: [String: NWSAlert],
                    timestamps: CAPTimestamps) -> NWSAlertChange? {
            let kind: NWSAlertChange.Kind
            switch properties.messageType {
            case "Update": kind = .update
            case "Cancel": kind = .cancellation
            default: return nil
            }
            guard properties.scope == "Public", let record = alertRecordURL(id),
                  properties.id == record.lastPathComponent,
                  let sent = timestamps.parse(properties.sent), sent <= checkedAt else { return nil }

            let affected = Set((properties.references ?? []).compactMap { reference -> String? in
                guard let link = reference.url.flatMap(alertRecordURL), let identifier = reference.identifier,
                      identifier == link.lastPathComponent,
                      let canonical = alertRecordURL("https://api.weather.gov/alerts/\(identifier)"),
                      canonical.lastPathComponent == identifier, canonical != record,
                      let sender = reference.sender, !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let priorSent = timestamps.parse(reference.sent), priorSent < sent else { return nil }
                let affectedID = canonical.absoluteString
                guard alerts[affectedID].map({ $0.sent == priorSent }) ?? true else { return nil }
                return affectedID
            }).sorted()
            guard !affected.isEmpty else { return nil }

            let prior = affected.lazy.compactMap { alerts[$0] }.first
            return NWSAlertChange(id: id, kind: kind, affectedIDs: affected, sent: sent,
                                  event: Self.nonempty(properties.event) ?? prior?.event ?? "Weather alert",
                                  headline: Self.nonempty(properties.headline),
                                  areaDescription: Self.nonempty(properties.areaDesc) ?? prior?.areaDescription ?? area)
        }

        private static func nonempty(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
    }

    private struct CAPTimestamps {
        let standard = ISO8601DateFormatter()
        let fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        func parse(_ text: String?) -> Date? {
            let pattern = #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z"#
            guard let text, text.utf8.count <= 64, text.range(of: pattern, options: .regularExpression) != nil else {
                return nil
            }
            return text.contains(".") ? fractional.date(from: text) : standard.date(from: text)
        }
    }
}

private func alertRecordURL(_ text: String) -> URL? {
    guard text.utf8.count <= 512, let parts = URLComponents(string: text),
          parts.scheme == "https", parts.host == "api.weather.gov",
          parts.user == nil, parts.password == nil, parts.port == nil,
          parts.query == nil, parts.fragment == nil, parts.path.hasPrefix("/alerts/") else { return nil }
    let identifier = parts.path.dropFirst("/alerts/".count)
    guard !identifier.isEmpty, identifier != ".", identifier != "..", identifier.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
    }) else { return nil }
    return parts.url
}

struct NWSAlertCache: Sendable {
    let directory: URL

    func read(area: String) -> NWSAlertSnapshot? {
        guard let file = file(for: area), let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(NWSAlertSnapshot.self, from: data), snapshot.area == area else {
            return nil
        }
        return snapshot
    }

    func write(_ snapshot: NWSAlertSnapshot) throws {
        guard let file = file(for: snapshot.area) else { throw NWSAlertError.invalidResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        var folder = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try folder.setResourceValues(resourceValues)
        #endif
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }

    private func file(for area: String) -> URL? {
        guard NWSAlertSnapshot.endpoint(for: area) != nil else { return nil }
        return directory.appendingPathComponent(area).appendingPathExtension("json")
    }
}

enum NWSAlertError: LocalizedError {
    case invalidResponse
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The National Weather Service response could not be verified as a complete alert list."
        case .responseTooLarge: "The National Weather Service alert list exceeded the download limit."
        }
    }
}
