import SwiftUI

struct WSDOTClosureView: View {
    enum RouteStatus: Sendable {
        case checking
        case unavailable
        case matched([WSDOTClosure])
    }

    @ObservedObject var store: WSDOTClosureStore
    @Binding var route: RouteStatus?
    @Environment(\.dismiss) private var dismiss

    private static let staleAfter: TimeInterval = 30 * 60

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Form {
                    settings
                    if store.enabled {
                        refreshStatus(at: context.date)
                        if let snapshot = store.snapshot {
                            closureList(snapshot)
                        }
                    }
                    Section("Coverage") {
                        Text(coverageDescription)
                        Link("WSDOT statewide travel map", destination: WSDOTClosureSnapshot.sourceURL)
                    }
                }
            }
            .navigationTitle(route == nil ? "WSDOT road closures" : "Route closure advisories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var coverageDescription: String {
        let south = WSDOTClosureSnapshot.south.formatted()
        let north = WSDOTClosureSnapshot.north.formatted()
        let west = abs(WSDOTClosureSnapshot.west).formatted()
        let east = abs(WSDOTClosureSnapshot.east).formatted()
        return "The Puget Sound pilot covers WSDOT roads between \(south)° and \(north)° N and \(west)° and \(east)° W."
    }

    private var settings: some View {
        Section {
            Toggle("Show WSDOT road closures", isOn: Binding(
                get: { store.enabled }, set: { store.setEnabled($0) }
            ))
            if store.enabled {
                Toggle("Allow metered connections", isOn: Binding(
                    get: { store.allowMetered }, set: { store.setAllowMetered($0) }
                ))
            }
        } footer: {
            Text("Saved closures appear as orange dashed lines. Route matching uses saved data on this device. Enable metered connections to check over cellular or in Low Data Mode.")
        }
    }

    private func refreshStatus(at date: Date) -> some View {
        Section("Refresh") {
            if let snapshot = store.snapshot {
                LabeledContent("Last successful check",
                               value: snapshot.checkedAt.formatted(date: .abbreviated, time: .shortened))
                if date.timeIntervalSince(snapshot.checkedAt) >= Self.staleAfter {
                    Label("Saved closures are stale and may omit newer reports.", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No saved WSDOT closure check.").foregroundStyle(.secondary)
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
            if store.isRefreshing {
                ProgressView("Checking for closures")
            } else {
                Button("Check for closures", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
            }
        }
    }

    @ViewBuilder
    private func closureList(_ snapshot: WSDOTClosureSnapshot) -> some View {
        if let route {
            Section {
                switch route {
                case .checking:
                    ProgressView("Checking saved closures near the route")
                case .unavailable:
                    Text("This route could not be checked within the Puget Sound pilot.").foregroundStyle(.secondary)
                case let .matched(closures):
                    if closures.isEmpty {
                        Text("No saved WSDOT closures matched this route.").foregroundStyle(.secondary)
                    } else {
                        ForEach(closures) { closure in closureRow(closure) }
                    }
                }
            } header: {
                Text("Saved closures near this route")
            } footer: {
                Text("Nearby matches are approximate and can include other roads or travel directions.")
            }
        } else {
            Section("Saved closures") {
                if snapshot.closures.isEmpty {
                    Text("No closures were reported at the last successful check.").foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.closures) { closure in closureRow(closure) }
                }
            }
        }
    }

    private func closureRow(_ closure: WSDOTClosure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(closure.road).font(.headline)
            if let direction = closure.direction, !direction.isEmpty {
                Text(direction).foregroundStyle(.secondary)
            }
            Text(closure.headline)
            if let updated = closure.updatedAt {
                Text("Reported \(updated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
