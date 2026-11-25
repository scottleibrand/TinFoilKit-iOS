import SwiftUI

struct NWSForecastSection: View {
    @ObservedObject var store: NWSAlertStore
    let date: Date

    var body: some View {
        Section {
            forecastRow(.daily)
            forecastRow(.hourly)
            if let error = store.forecastErrorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
            if store.forecastIsRefreshing {
                ProgressView("Checking Seattle forecasts")
            } else {
                Button("Check Seattle forecasts", systemImage: "arrow.clockwise") {
                    Task { await store.refreshForecasts() }
                }
            }
        } header: {
            Text("Seattle city center forecasts")
        } footer: {
            Text("Forecasts use a fixed city-center location. Times are Pacific Time. Saved forecasts are available offline.")
        }
    }

    @ViewBuilder
    private func forecastRow(_ kind: NWSForecastKind) -> some View {
        let title = NWSForecastDisplay.title(kind)
        if let snapshot = store.forecasts[kind] {
            NavigationLink {
                NWSForecastDetailsView(store: store, kind: kind)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text("Checked \(NWSForecastDisplay.timestamp(snapshot.checkedAt))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let status = NWSForecastDisplay.status(snapshot, at: date) {
                        Label(status, systemImage: "clock.badge.exclamationmark")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            LabeledContent(title, value: "No saved forecast")
        }
    }
}

private struct NWSForecastDetailsView: View {
    @ObservedObject var store: NWSAlertStore
    let kind: NWSForecastKind

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            List {
                if store.area == "WA", let snapshot = store.forecasts[kind] {
                    forecastStatus(snapshot, at: context.date)
                    periods(snapshot.periods, at: context.date)
                } else {
                    Text("No saved forecast.").foregroundStyle(.secondary)
                }
            }
            .refreshable { await store.refreshForecasts() }
        }
        .navigationTitle(NWSForecastDisplay.title(kind))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func forecastStatus(_ snapshot: NWSForecastSnapshot, at date: Date) -> some View {
        Section {
            LabeledContent("Last successful check", value: NWSForecastDisplay.timestamp(snapshot.checkedAt))
            LabeledContent("Source updated", value: NWSForecastDisplay.timestamp(snapshot.sourceUpdatedAt))
            if let expires = snapshot.expiresAt {
                LabeledContent("Publisher cache expires", value: NWSForecastDisplay.timestamp(expires))
            }
            if let status = NWSForecastDisplay.status(snapshot, at: date) {
                Label(status, systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
            }
            if let error = store.forecastErrorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
        } header: {
            Text("Seattle city center · Pacific Time")
        }
    }

    @ViewBuilder
    private func periods(_ periods: [NWSForecastPeriod], at date: Date) -> some View {
        let remaining = periods.filter { $0.end > date }
        let ended = periods.filter { $0.end <= date }
        if !remaining.isEmpty {
            Section("Remaining periods") {
                ForEach(remaining) { period in periodRow(period) }
            }
        }
        if !ended.isEmpty {
            Section {
                DisclosureGroup("Ended periods") {
                    ForEach(ended) { period in periodRow(period) }
                }
            }
        }
    }

    private func periodRow(_ period: NWSForecastPeriod) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !period.name.isEmpty {
                Text(period.name).font(.headline)
            }
            Text("\(NWSForecastDisplay.timestamp(period.start)) – \(NWSForecastDisplay.timestamp(period.end))")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("\(period.temperature.formatted())°\(period.temperatureUnit) · \(period.shortForecast)")
            if let detail = period.detailedForecast, !detail.isEmpty, detail != period.shortForecast {
                Text(detail).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

private enum NWSForecastDisplay {
    static let staleAfter: TimeInterval = 3 * 60 * 60
    private static let seattleTime = TimeZone(identifier: "America/Los_Angeles")!
    private static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: seattleTime)

    static func title(_ kind: NWSForecastKind) -> String {
        switch kind {
        case .daily: "Daily forecast"
        case .hourly: "Hourly forecast"
        }
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(dateStyle)
    }

    static func status(_ snapshot: NWSForecastSnapshot, at date: Date) -> String? {
        if snapshot.periods.allSatisfy({ $0.end <= date }) {
            return "Saved forecast has expired. All periods have ended."
        }
        if date.timeIntervalSince(snapshot.checkedAt) >= staleAfter {
            return "Saved forecast is stale and may have changed."
        }
        return nil
    }
}
