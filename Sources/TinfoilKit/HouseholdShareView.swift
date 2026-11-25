import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Network
import SwiftUI

struct HouseholdShareView: View {
    let snapshot: HouseholdSnapshot
    let canAcceptGuestNotes: Bool
    let appendGuestNote: (String) throws -> Void
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = HouseholdShareSession()
    @State private var includeNotes = false
    @State private var includeHome = false
    @State private var includePins = false
    @State private var selectedReferenceIDs: Set<String> = []
    @State private var acceptGuestNotes = false
    @State private var noteError: String?
    @State private var publicReferences: [HouseholdSharePublicReference] = []

    var body: some View {
        Form {
            Section("Share a copy") {
                if hasNotes { Toggle("Notes", isOn: $includeNotes).disabled(session.running) }
                if snapshot.home != nil { Toggle("Home location", isOn: $includeHome).disabled(session.running) }
                if !snapshot.pins.isEmpty { Toggle("Saved pins", isOn: $includePins).disabled(session.running) }
                if !hasNotes && snapshot.home == nil && snapshot.pins.isEmpty && publicReferences.isEmpty {
                    Text("Add household information before sharing.").foregroundStyle(.secondary)
                }
            }
            if !publicReferences.isEmpty {
                Section("Public reference templates") {
                    ForEach(publicReferences) { reference in
                        Toggle(reference.title, isOn: Binding(
                            get: { selectedReferenceIDs.contains(reference.id) },
                            set: { selected in
                                if selected {
                                    selectedReferenceIDs.insert(reference.id)
                                } else {
                                    selectedReferenceIDs.remove(reference.id)
                                }
                            }
                        ))
                        .disabled(session.running)
                    }
                }
            }
            Section {
                Toggle("Allow guests to send notes", isOn: $acceptGuestNotes)
                    .disabled(session.running || !canAcceptGuestNotes)
            } footer: {
                Text("Review notes on this phone before adding them to Household.")
            }
            if let note = session.proposedNote {
                Section("Guest note") {
                    Text(note).textSelection(.enabled)
                    Button("Append to household notes") { append(note) }
                    Button("Discard", role: .destructive) {
                        noteError = nil
                        session.finishNoteReview()
                    }
                    if let noteError { Text(noteError).foregroundStyle(.secondary) }
                }
            }
            Section {
                switch session.state {
                case .ready(let link):
                    ShareLink(item: link) {
                        Label("Share local link", systemImage: "square.and.arrow.up")
                    }
                    if let code = qrCode(for: link) {
                        DisclosureGroup("Show QR code") {
                            Image(decorative: code, scale: 1)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 176, height: 176)
                                .padding(12)
                                .background(.white)
                                .accessibilityLabel("Local sharing QR code")
                        }
                    }
                    Button("Replace link", systemImage: "arrow.clockwise") { session.replaceLink() }
                    Button("Stop sharing", role: .destructive) { session.stop() }
                case .starting:
                    ProgressView("Starting local sharing")
                    Button("Cancel", role: .cancel) { session.stop() }
                case .replacing:
                    ProgressView("Replacing link")
                    Button("Stop sharing", role: .destructive) { session.stop() }
                case .idle:
                    startSharing
                case .message(let text):
                    Text(text).foregroundStyle(.secondary)
                    startSharing
                }
            } footer: {
                Text("Use a trusted Wi-Fi or Ethernet network. The link isn't encrypted, so anyone on that network who has the link or can watch its traffic can read your selection until you leave this screen or 10 minutes pass. Replacing the link revokes the previous link.")
            }
        }
        .navigationTitle("Share on local network")
        .task {
            publicReferences = HouseholdSharePublicReference.verified(from: NearbyPublicReference.catalogReferences)
        }
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) {
            if scenePhase == .background { session.stop() }
        }
    }

    private func append(_ note: String) {
        do {
            try appendGuestNote(note)
            noteError = nil
            session.finishNoteReview()
        } catch {
            noteError = error.localizedDescription
        }
    }

    private static let imageContext = CIContext()

    private func qrCode(for link: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.absoluteString.utf8)
        guard let output = filter.outputImage else { return nil }
        return Self.imageContext.createCGImage(output, from: output.extent)
    }

    private var hasNotes: Bool { !snapshot.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var selectedReferences: [HouseholdSharePublicReference] {
        publicReferences.filter { selectedReferenceIDs.contains($0.id) }
    }

    private var startSharing: some View {
        Button("Start sharing", systemImage: "person.2") {
            session.start(HouseholdSnapshot(
                notes: includeNotes ? snapshot.notes : "",
                home: includeHome ? snapshot.home : nil,
                pins: includePins ? snapshot.pins : []
            ), publicReferences: selectedReferences,
               acceptsNotes: acceptGuestNotes && canAcceptGuestNotes)
        }
        .disabled(!((includeNotes && hasNotes) || (includeHome && snapshot.home != nil) ||
                    (includePins && !snapshot.pins.isEmpty) || !selectedReferences.isEmpty ||
                    (acceptGuestNotes && canAcceptGuestNotes)))
    }
}

@MainActor
private final class HouseholdShareSession: ObservableObject {
    enum State {
        case idle, starting, replacing, ready(URL), message(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var proposedNote: String?
    private var server: HouseholdShareServer?
    private var monitor: NWPathMonitor?
    private var startup: Task<Void, Never>?
    private var address: HouseholdShareAddress?
    private var attempt: UUID?

    var running: Bool {
        switch state {
        case .starting, .replacing, .ready: true
        default: false
        }
    }

    func start(_ snapshot: HouseholdSnapshot, publicReferences: [HouseholdSharePublicReference], acceptsNotes: Bool) {
        guard attempt == nil else { return }
        let id = UUID()
        let page = HouseholdSharePage(snapshot: snapshot, publicReferences: publicReferences, acceptsNotes: acceptsNotes)
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

    func finishNoteReview() {
        proposedNote = nil
        server?.finishNoteReview()
    }

    func replaceLink() {
        guard case .ready = state, let server else { return }
        state = .replacing
        server.replaceLink()
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
        proposedNote = nil
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
        case let .noteProposed(note):
            proposedNote = note
        case let .failed(error):
            end(.message(error))
        case .expired:
            end(.message("The local link expired."))
        }
    }
}
