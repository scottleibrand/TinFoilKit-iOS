import Foundation

struct RegionalMonitorStatus: Sendable {
    enum Source: Equatable, Sendable {
        case weather, roads
    }

    enum Coverage: Equatable, Sendable {
        case weatherArea(String?)
        case pugetSoundPilot
    }

    enum SourceState: Equatable, Sendable {
        case off, outsideCoverage, noArea, unchecked
        case saved(checkedAt: Date, stale: Bool, count: Int)
    }

    struct SourceStatus: Equatable, Sendable {
        let source: Source
        let coverage: Coverage
        let state: SourceState
        let sourceUpdatedAt: Date?
    }

    struct Entry: Identifiable, Sendable {
        enum Kind: Sendable {
            case alert(NWSAlert)
            case change(NWSAlertChange)
            case closure(WSDOTClosure)
        }

        let kind: Kind
        var alertChange: NWSAlertChange? = nil

        var id: String {
            switch kind {
            case .alert(let alert): "nws:\(alert.id)"
            case .change(let change): "nws:\(change.id)"
            case .closure(let closure): "wsdot:\(closure.id)"
            }
        }

        var source: Source {
            switch kind {
            case .alert, .change: .weather
            case .closure: .roads
            }
        }

        var date: Date? {
            switch kind {
            case .alert(let alert): alert.sent
            case .change(let change): change.sent
            case .closure(let closure): closure.updatedAt
            }
        }

        var expiresAt: Date? {
            if case .alert(let alert) = kind { return alert.expires }
            return nil
        }
    }

    let weatherStatus: SourceStatus
    let roadStatus: SourceStatus
    let entries: [Entry]

    init(area: String, weather: NWSAlertSnapshot?, roadClosures: WSDOTClosureSnapshot?, roadsEnabled: Bool, now: Date) {
        var timeline: [Entry] = []

        let weatherState: SourceState
        var weatherUpdatedAt: Date?
        if area.isEmpty {
            weatherState = .noArea
        } else if let weather, weather.area == area {
            let alertIDs = Set(weather.alerts.map(\.id))
            var changes: [String: NWSAlertChange] = [:]
            for change in weather.changes {
                if let previous = changes[change.id], previous.sent >= change.sent { continue }
                changes[change.id] = change
            }
            timeline += weather.alerts.map { Entry(kind: .alert($0), alertChange: changes[$0.id]) }
            timeline += changes.values.filter { !alertIDs.contains($0.id) }.map { Entry(kind: .change($0)) }
            let unexpired = weather.alerts.filter { $0.expires > now }.count
            weatherState = Self.saved(at: weather.checkedAt, now: now, count: unexpired)
            weatherUpdatedAt = weather.sourceUpdatedAt
        } else {
            weatherState = .unchecked
        }
        weatherStatus = SourceStatus(source: .weather, coverage: .weatherArea(area.isEmpty ? nil : area),
                                     state: weatherState, sourceUpdatedAt: weatherUpdatedAt)

        let roadState: SourceState
        if area != "WA" {
            roadState = .outsideCoverage
        } else if !roadsEnabled {
            roadState = .off
        } else if let roadClosures {
            timeline += roadClosures.closures.map { Entry(kind: .closure($0)) }
            roadState = Self.saved(at: roadClosures.checkedAt, now: now, count: roadClosures.closures.count)
        } else {
            roadState = .unchecked
        }
        roadStatus = SourceStatus(source: .roads, coverage: .pugetSoundPilot, state: roadState, sourceUpdatedAt: nil)

        entries = timeline.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?) where left != right: left > right
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.id < rhs.id
            }
        }
    }

    private static func saved(at checkedAt: Date, now: Date, count: Int) -> SourceState {
        .saved(checkedAt: checkedAt, stale: now.timeIntervalSince(checkedAt) >= 30 * 60, count: count)
    }
}
