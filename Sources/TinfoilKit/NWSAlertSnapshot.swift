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
}

struct NWSAlertSnapshot: Codable, Sendable {
    static let maximumResponseBytes = 2 * 1024 * 1024

    let area: String
    let checkedAt: Date
    let sourceUpdatedAt: Date?
    let etag: String?
    let lastModified: String?
    let alerts: [NWSAlert]

    static func endpoint(for area: String) -> URL? {
        guard area.utf8.count == 2, area.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return URL(string: "https://api.weather.gov/alerts/active?area=\(area)&status=actual")
    }

    func revalidated(at date: Date, etag: String?, lastModified: String?) -> Self {
        Self(area: area, checkedAt: date, sourceUpdatedAt: sourceUpdatedAt, etag: etag ?? self.etag,
             lastModified: lastModified ?? self.lastModified, alerts: alerts)
    }

    static func decode(_ data: Data, area: String, checkedAt: Date, etag: String?, lastModified: String?) throws -> Self {
        guard data.count <= maximumResponseBytes else { throw NWSAlertError.responseTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let collection = try decoder.decode(Collection.self, from: data)
        guard collection.type == "FeatureCollection", collection.pagination?.next == nil else {
            throw NWSAlertError.invalidResponse
        }
        var alerts: [String: NWSAlert] = [:]
        var superseded: Set<String> = []
        for feature in collection.features {
            let value = feature.properties
            guard value.status == "Actual" else { continue }
            if value.messageType == "Update" || value.messageType == "Cancel" {
                superseded.formUnion((value.references ?? []).compactMap(\.url))
            }
            guard value.messageType == "Alert" || value.messageType == "Update" else { continue }
            guard !feature.id.isEmpty, !value.event.isEmpty, value.expires >= value.sent else {
                throw NWSAlertError.invalidResponse
            }
            if let previous = alerts[feature.id], previous.sent >= value.sent { continue }
            alerts[feature.id] = NWSAlert(id: feature.id, event: value.event, headline: value.headline,
                                         areaDescription: value.areaDesc, description: value.description,
                                         instruction: value.instruction, sent: value.sent, expires: value.expires)
        }
        for id in superseded { alerts.removeValue(forKey: id) }
        return Self(area: area, checkedAt: checkedAt, sourceUpdatedAt: collection.updated, etag: etag, lastModified: lastModified,
                    alerts: alerts.values.sorted { ($0.sent, $0.id) > ($1.sent, $1.id) })
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
                enum CodingKeys: String, CodingKey { case url = "@id" }
            }

            let status: String
            let messageType: String
            let event: String
            let headline: String?
            let areaDesc: String
            let description: String
            let instruction: String?
            let sent: Date
            let expires: Date
            let references: [Reference]?
        }

        let id: String
        let properties: Properties
    }
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
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The National Weather Service response could not be verified as a complete alert list."
        case .responseTooLarge: "The National Weather Service alert list exceeded the download limit."
        case let .httpStatus(status): "The National Weather Service returned HTTP \(status)."
        }
    }
}
