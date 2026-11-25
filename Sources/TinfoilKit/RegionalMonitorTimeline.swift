import SwiftUI

struct MonitorSourceRow: View {
    let title: String
    let coverage: String
    let status: RegionalMonitorStatus.SourceStatus
    let empty: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(coverage)
            switch status.state {
            case .off:
                Text("Off")
            case .outsideCoverage:
                Text("Outside the pilot area")
            case .noArea, .unchecked:
                Text("No saved check")
            case let .saved(checkedAt, stale, count):
                Text("Checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                if let updated = status.sourceUpdatedAt {
                    Text("Source updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                }
                Text(count == 0 ? empty : "\(count.formatted()) in the saved check")
                if stale {
                    Label("Stale · newer reports may be missing", systemImage: "clock.badge.exclamationmark")
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

struct RegionalMonitorTimeline: View {
    let entries: [RegionalMonitorStatus.Entry]
    let now: Date

    var body: some View {
        let reports = entries.filter { $0.expiresAt.map { $0 > now } ?? true }
        let expired = entries.filter { $0.expiresAt.map { $0 <= now } ?? false }
        if !reports.isEmpty {
            Section {
                ForEach(reports) { entry in
                    report(entry)
                }
            } header: {
                Text("Saved reports")
            } footer: {
                Text("Reports come from the latest saved check for each source.")
            }
        }
        if !expired.isEmpty {
            Section {
                DisclosureGroup("Expired saved alerts") {
                    ForEach(expired) { entry in
                        report(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func report(_ entry: RegionalMonitorStatus.Entry) -> some View {
        switch entry.kind {
        case let .alert(alert):
            NavigationLink {
                NWSAlertDetailsView(alert: alert)
            } label: {
                row(alert.event, area: alert.areaDescription, publisher: entry.alertChange == nil ? "NWS alert" : "NWS update",
                    date: entry.date)
            }
        case let .change(change):
            NavigationLink {
                List {
                    Section {
                        Text(change.areaDescription)
                        LabeledContent("Issued", value: change.sent.formatted(date: .abbreviated, time: .shortened))
                        if !change.affectedIDs.isEmpty {
                            LabeledContent("Referenced alerts", value: change.affectedIDs.count.formatted())
                        }
                        if let headline = change.headline, !headline.isEmpty { Text(headline) }
                        if let source = change.sourceURL { Link("NWS source record", destination: source) }
                    }
                }
                .navigationTitle(change.kind == .cancellation ? "NWS cancellation" : "NWS update")
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                row(change.event, area: change.areaDescription,
                    publisher: change.kind == .cancellation ? "NWS cancellation" : "NWS update", date: entry.date)
            }
        case let .closure(closure):
            NavigationLink {
                List {
                    Section {
                        WSDOTClosureSummary(closure: closure)
                        Link("WSDOT travel map", destination: WSDOTClosureSnapshot.sourceURL)
                    } footer: {
                        Text("Saved WSDOT Puget Sound advisory. Road conditions may have changed.")
                    }
                }
                .navigationTitle(closure.road)
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                row(closure.road, area: closure.direction ?? "Puget Sound", publisher: "WSDOT closure", date: entry.date)
            }
        }
    }

    private func row(_ title: String, area: String, publisher: String, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if !area.isEmpty { Text(area) }
            Text(publisher + " · " + (date?.formatted(date: .abbreviated, time: .shortened) ?? "Report time unavailable"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
