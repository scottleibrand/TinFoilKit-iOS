import SwiftUI

struct NWSUpdatesView: View {
    @ObservedObject var store: NWSAlertStore
    @ObservedObject var roads: WSDOTClosureStore
    @State private var showingRoadClosures = false
    @State private var checking = false

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
                        let status = RegionalMonitorStatus(
                            area: store.area, weather: store.snapshot, roadClosures: roads.snapshot,
                            roadsEnabled: roads.enabled, now: context.date
                        )
                        regionalStatus(status)
                        RegionalMonitorTimeline(entries: status.entries, now: context.date)
                    }
                    NWSForecastSection(store: store, date: context.date)
                    Section {
                        Link("National Weather Service · weather.gov", destination: Self.sourceURL)
                    } footer: {
                        Text("Keep official emergency alerts enabled for urgent warnings.")
                    }
                }
                .refreshable { await checkUpdates() }
            }
            .navigationTitle("Updates")
            .sheet(isPresented: $showingRoadClosures) {
                WSDOTClosureView(store: roads, route: .constant(nil))
            }
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

    private func regionalStatus(_ status: RegionalMonitorStatus) -> some View {
        Section {
            MonitorSourceRow(title: "NWS weather alerts", coverage: Self.areas.first { $0.code == store.area }?.name ?? store.area,
                             status: status.weatherStatus, empty: "No unexpired alerts in the saved check")
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
            if store.area == "WA" {
                MonitorSourceRow(title: "WSDOT road closures", coverage: "Puget Sound pilot",
                                 status: status.roadStatus, empty: "No closures in the saved check")
                if let error = roads.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
                Button("Road closure settings", systemImage: "road.lanes") { showingRoadClosures = true }
            }
            if checking || store.isRefreshing || (store.area == "WA" && roads.isRefreshing) {
                ProgressView("Checking for updates")
            } else {
                Button("Check for updates", systemImage: "arrow.clockwise") {
                    Task { await checkUpdates() }
                }
            }
        } header: {
            Text("Regional status")
        } footer: {
            Text("Each source has its own coverage and last successful check.")
        }
    }

    @MainActor
    private func checkUpdates() async {
        guard !checking, !store.area.isEmpty else { return }
        checking = true
        defer { checking = false }
        let area = store.area
        await store.refreshAlerts()
        guard !Task.isCancelled, store.area == area else { return }
        if area == "WA" { await roads.refresh() }
        if !Task.isCancelled, store.area == area {
            await store.refreshForecasts()
        }
    }
}

struct NWSAlertDetailsView: View {
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
                    if let source = alert.sourceURL { Link("NWS source record", destination: source) }
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
