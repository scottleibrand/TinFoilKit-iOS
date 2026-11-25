import SwiftUI

struct NWSForecastSection: View {
    @ObservedObject var store: NWSAlertStore
    let date: Date
    @State private var coordinates = ""
    @FocusState private var editingCoordinates: Bool

    var body: some View {
        Section {
            TextField("Latitude, longitude", text: $coordinates)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($editingCoordinates)
            let proposed = NWSForecastLocation(coordinates)
            Button("Use these coordinates") {
                if let proposed {
                    coordinates = proposed.coordinates
                    editingCoordinates = false
                    store.setForecastLocation(proposed)
                }
            }
            .disabled(proposed == nil || proposed == store.forecastLocation)
            if let location = store.forecastLocation {
                LabeledContent("Forecast location", value: location.coordinates)
                forecastRow(.daily)
                forecastRow(.hourly)
                if let error = store.forecastErrorMessage {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
                if store.forecastIsRefreshing {
                    ProgressView("Checking forecasts")
                } else {
                    Button("Check forecasts", systemImage: "arrow.clockwise") {
                        Task { await store.refreshForecasts() }
                    }
                }
                Button("Remove forecast location", role: .destructive) {
                    coordinates = ""
                    store.setForecastLocation(nil)
                }
            }
        } header: {
            Text("Local forecast")
        } footer: {
            Text("Enter decimal coordinates for a location covered by the National Weather Service. The app sends those coordinates rounded to two decimal places to weather.gov and saves the forecast for offline use.")
        }
        .onAppear {
            if coordinates.isEmpty { coordinates = store.forecastLocation?.coordinates ?? "" }
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
                    Text("Checked \(NWSForecastDisplay.timestamp(snapshot.checkedAt, in: store.forecastTimeZone))")
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
                if let snapshot = store.forecasts[kind] {
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
            LabeledContent("Last successful check", value: timestamp(snapshot.checkedAt))
            LabeledContent("Source updated", value: timestamp(snapshot.sourceUpdatedAt))
            if let expires = snapshot.expiresAt {
                LabeledContent("Publisher cache expires", value: timestamp(expires))
            }
            if let status = NWSForecastDisplay.status(snapshot, at: date) {
                Label(status, systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
            }
            if let error = store.forecastErrorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
        } header: {
            Text(store.forecastTimeZone.identifier)
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
            Text("\(timestamp(period.start)) – \(timestamp(period.end))")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("\(period.temperature.formatted())°\(period.temperatureUnit) · \(period.shortForecast)")
            if let detail = period.detailedForecast, !detail.isEmpty, detail != period.shortForecast {
                Text(detail).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private func timestamp(_ date: Date) -> String {
        NWSForecastDisplay.timestamp(date, in: store.forecastTimeZone)
    }
}

private enum NWSForecastDisplay {
    static let staleAfter: TimeInterval = 3 * 60 * 60

    static func title(_ kind: NWSForecastKind) -> String {
        switch kind {
        case .daily: "Daily forecast"
        case .hourly: "Hourly forecast"
        }
    }

    static func timestamp(_ date: Date, in timeZone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone))
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
