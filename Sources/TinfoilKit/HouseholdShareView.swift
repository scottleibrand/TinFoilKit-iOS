import Foundation
import Network
import SwiftUI

struct HouseholdShareView: View {
    let snapshot: HouseholdSnapshot
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = HouseholdShareSession()
    @State private var includeNotes = false
    @State private var includeHome = false
    @State private var includePins = false

    var body: some View {
        Form {
            Section("Share a copy") {
                if hasNotes { Toggle("Notes", isOn: $includeNotes).disabled(session.running) }
                if snapshot.home != nil { Toggle("Home location", isOn: $includeHome).disabled(session.running) }
                if !snapshot.pins.isEmpty { Toggle("Saved pins", isOn: $includePins).disabled(session.running) }
                if !hasNotes && snapshot.home == nil && snapshot.pins.isEmpty {
                    Text("Add household information before sharing.").foregroundStyle(.secondary)
                }
            }
            Section {
                switch session.state {
                case .ready(let link):
                    ShareLink(item: link) {
                        Label("Share private link", systemImage: "square.and.arrow.up")
                    }
                    Button("Stop sharing", role: .destructive) { session.stop() }
                case .starting:
                    ProgressView("Starting local sharing")
                    Button("Cancel", role: .cancel) { session.stop() }
                case .idle:
                    startSharing
                case .message(let text):
                    Text(text).foregroundStyle(.secondary)
                    startSharing
                }
            } footer: {
                Text("Use a trusted Wi-Fi or Ethernet network. Anyone with the link on that network can read your selection until you leave this screen or 10 minutes pass.")
            }
        }
        .navigationTitle("Share on local network")
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) {
            if scenePhase == .background { session.stop() }
        }
    }

    private var hasNotes: Bool { !snapshot.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var startSharing: some View {
        Button("Start sharing", systemImage: "person.2") {
            session.start(HouseholdSnapshot(
                notes: includeNotes ? snapshot.notes : "",
                home: includeHome ? snapshot.home : nil,
                pins: includePins ? snapshot.pins : []
            ))
        }
        .disabled(!((includeNotes && hasNotes) || (includeHome && snapshot.home != nil) ||
                    (includePins && !snapshot.pins.isEmpty)))
    }
}

@MainActor
private final class HouseholdShareSession: ObservableObject {
    enum State {
        case idle, starting, ready(URL), message(String)
    }

    @Published private(set) var state: State = .idle
    private var server: HouseholdShareServer?
    private var monitor: NWPathMonitor?
    private var startup: Task<Void, Never>?
    private var address: HouseholdShareAddress?
    private var attempt: UUID?

    var running: Bool {
        switch state {
        case .starting, .ready: true
        default: false
        }
    }

    func start(_ snapshot: HouseholdSnapshot) {
        guard attempt == nil else { return }
        let id = UUID()
        let page = HouseholdSharePage(snapshot: snapshot)
        attempt = id
        state = .starting
        // Bound the wait even if path discovery does not report an interface.
        startup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, self?.attempt == id {
                self?.end(.message("Could not start sharing. Check that this phone is connected to your local network."))
            }
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let localAddress = HouseholdShareAddress.local(in: path.availableInterfaces)
            Task { @MainActor in self?.pathChanged(localAddress, page: page, attempt: id) }
        }
        monitor.start(queue: DispatchQueue(label: "org.tinfoilkit.share-path"))
    }

    func stop() {
        end(.idle)
    }

    private func end(_ newState: State) {
        attempt = nil
        startup?.cancel()
        startup = nil
        monitor?.cancel()
        monitor = nil
        server?.stop()
        server = nil
        address = nil
        state = newState
    }

    private func pathChanged(_ next: HouseholdShareAddress?, page: HouseholdSharePage, attempt: UUID) {
        guard self.attempt == attempt else { return }
        if let address {
            if next != address {
                end(.message("Sharing stopped because the local network changed."))
            }
            return
        }
        guard let next else { return }
        do {
            let server = try HouseholdShareServer(address: next, page: page) { [weak self] event in
                Task { @MainActor in self?.receive(event, attempt: attempt) }
            }
            address = next
            self.server = server
            server.start()
        } catch {
            end(.message(error.localizedDescription))
        }
    }

    private func receive(_ event: HouseholdShareServer.Event, attempt: UUID) {
        guard self.attempt == attempt else { return }
        switch event {
        case let .listening(url):
            startup?.cancel()
            startup = nil
            state = .ready(url)
        case let .failed(error):
            end(.message(error))
        case .expired:
            end(.message("The private link expired."))
        }
    }
}
