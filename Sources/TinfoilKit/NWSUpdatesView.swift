import SwiftUI

struct NWSUpdatesView: View {
    @ObservedObject var store: NWSAlertStore

    private static let staleAfter: TimeInterval = 30 * 60
    private static let sourceURL = URL(string: "https://www.weather.gov/")!
    private static let areas: [(code: String, name: String)] = [
        ("AL", "Alabama"), ("AK", "Alaska"), ("AS", "American Samoa"), ("AZ", "Arizona"),
        ("AR", "Arkansas"), ("CA", "California"), ("CO", "Colorado"), ("CT", "Connecticut"),
        ("DE", "Delaware"), ("DC", "District of Columbia"), ("FL", "Florida"), ("GA", "Georgia"),
        ("GU", "Guam"), ("HI", "Hawaii"), ("ID", "Idaho"), ("IL", "Illinois"),
        ("IN", "Indiana"), ("IA", "Iowa"), ("KS", "Kansas"), ("KY", "Kentucky"),
        ("LA", "Louisiana"), ("ME", "Maine"), ("MD", "Maryland"), ("MA", "Massachusetts"),
        ("MI", "Michigan"), ("MN", "Minnesota"), ("MS", "Mississippi"), ("MO", "Missouri"),
        ("MT", "Montana"), ("NE", "Nebraska"), ("NV", "Nevada"), ("NH", "New Hampshire"),
        ("NJ", "New Jersey"), ("NM", "New Mexico"), ("NY", "New York"), ("NC", "North Carolina"),
        ("ND", "North Dakota"), ("MP", "Northern Mariana Islands"), ("OH", "Ohio"), ("OK", "Oklahoma"),
        ("OR", "Oregon"), ("PA", "Pennsylvania"), ("PR", "Puerto Rico"), ("RI", "Rhode Island"),
        ("SC", "South Carolina"), ("SD", "South Dakota"), ("TN", "Tennessee"), ("TX", "Texas"),
        ("VI", "U.S. Virgin Islands"), ("UT", "Utah"), ("VT", "Vermont"), ("VA", "Virginia"),
        ("WA", "Washington"), ("WV", "West Virginia"), ("WI", "Wisconsin"), ("WY", "Wyoming")
    ]

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Form {
                    settings
                    if !store.area.isEmpty {
                        checkStatus(at: context.date)
                        if let snapshot = store.snapshot {
                            savedAlerts(snapshot, at: context.date)
                        }
                    }
                    if store.area == "WA" {
                        NWSForecastSection(store: store, date: context.date)
                    }
                    Section {
                        Link("National Weather Service · weather.gov", destination: Self.sourceURL)
                    } footer: {
                        Text("Keep official emergency alerts enabled for urgent warnings.")
                    }
                }
                .refreshable { await store.refresh() }
            }
            .navigationTitle("Updates")
        }
    }

    private var settings: some View {
        Section {
            Picker("State or territory", selection: Binding(
                get: { store.area },
                set: { store.setArea($0) }
            )) {
                Text("Choose an area").tag("")
                ForEach(Self.areas.indices, id: \.self) { index in
                    let area = Self.areas[index]
                    Text(area.name).tag(area.code)
                }
            }
            .pickerStyle(.navigationLink)
            Toggle("Allow metered connections", isOn: Binding(
                get: { store.allowMetered },
                set: { store.setAllowMetered($0) }
            ))
        } header: {
            Text("Weather alerts")
        } footer: {
            Text("Checks cover the selected state or territory and require an internet connection. Saved alerts are available offline. Enable metered connections to check over cellular or in Low Data Mode.")
        }
    }

    private func checkStatus(at date: Date) -> some View {
        Section("Refresh") {
            if let snapshot = store.snapshot {
                LabeledContent("Last successful check",
                               value: snapshot.checkedAt.formatted(date: .abbreviated, time: .shortened))
                if let sourceUpdatedAt = snapshot.sourceUpdatedAt {
                    LabeledContent("Source updated",
                                   value: sourceUpdatedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if isStale(snapshot, at: date) {
                    Label("Saved alerts are stale and may omit newer alerts.", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No saved alert check for this area.").foregroundStyle(.secondary)
            }

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }

            if store.isRefreshing {
                ProgressView("Checking for alerts")
            } else {
                Button("Check for alerts", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
            }
        }
    }

    @ViewBuilder
    private func savedAlerts(_ snapshot: NWSAlertSnapshot, at date: Date) -> some View {
        let active = snapshot.alerts.filter { $0.expires > date }
        let expired = snapshot.alerts.filter { $0.expires <= date }

        Section(isStale(snapshot, at: date) ? "Unexpired saved alerts" : "Saved active alerts") {
            if snapshot.alerts.isEmpty {
                Text("No alerts were reported at the last successful check.").foregroundStyle(.secondary)
            } else if active.isEmpty {
                Text("All saved alerts have expired.").foregroundStyle(.secondary)
            } else {
                ForEach(active) { alert in
                    alertLink(alert)
                }
            }
        }
        if !expired.isEmpty {
            Section("Expired saved alerts") {
                ForEach(expired) { alert in
                    alertLink(alert)
                }
            }
        }
    }

    private func alertLink(_ alert: NWSAlert) -> some View {
        NavigationLink {
            NWSAlertDetailsView(alert: alert)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.event).font(.headline)
                Text(alert.areaDescription).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func isStale(_ snapshot: NWSAlertSnapshot, at date: Date) -> Bool {
        date.timeIntervalSince(snapshot.checkedAt) >= Self.staleAfter
    }
}

private struct NWSAlertDetailsView: View {
    let alert: NWSAlert

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            List {
                Section {
                    if alert.expires <= context.date {
                        Label("Expired saved alert", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                    if let headline = alert.headline, !headline.isEmpty {
                        Text(headline).font(.headline)
                    }
                    Text(alert.areaDescription)
                    LabeledContent("Issued", value: alert.sent.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Expires", value: alert.expires.formatted(date: .abbreviated, time: .shortened))
                }
                alertSection("Details", text: alert.description)
                alertSection("Instructions from the National Weather Service", text: alert.instruction)
            }
        }
        .navigationTitle(alert.event)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func alertSection(_ title: String, text: String?) -> some View {
        if let text, !text.isEmpty {
            Section(title) {
                Text(text).textSelection(.enabled)
            }
        }
    }
}
