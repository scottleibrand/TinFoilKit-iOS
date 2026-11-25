import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import Network
import SwiftSoup
import SwiftUI
import ZIMArchive

struct HouseholdShareView: View {
    let snapshot: HouseholdSnapshot
    let canAcceptGuestProposals: Bool
    let appendGuestNote: (String) throws -> Void
    let saveGuestPin: (HouseholdPlace) throws -> Void
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = HouseholdShareSession()
    @State private var includeNotes = false
    @State private var includeHome = false
    @State private var includePins = false
    @State private var includeDirections = false
    @State private var selectedReferenceIDs: Set<String> = []
    @State private var acceptGuestNotes = false
    @State private var acceptGuestPins = false
    @State private var proposalError: String?
    @State private var publicReferences: [HouseholdSharePublicReference] = []

    var body: some View {
        Form {
            Section {
                if hasNotes { Toggle("Notes", isOn: $includeNotes).disabled(session.running) }
                if snapshot.home != nil { Toggle("Home location", isOn: $includeHome).disabled(session.running) }
                if !snapshot.pins.isEmpty { Toggle("Saved pins", isOn: $includePins).disabled(session.running) }
                if includeHome && includePins && snapshot.home != nil && !snapshot.pins.isEmpty {
                    Toggle("Directions from Home to pins", isOn: $includeDirections).disabled(session.running)
                }
                if !hasNotes && snapshot.home == nil && snapshot.pins.isEmpty && publicReferences.isEmpty {
                    Text("Add household information before sharing.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Share a copy")
            } footer: {
                if snapshot.home != nil || !snapshot.pins.isEmpty {
                    Text("Guests can save the names and coordinates of shared locations as a GPX file.")
                }
                if includeHome && includePins && includeDirections {
                    Text("Share walking and driving steps for up to the first three pins where installed routing data can calculate a route.")
                }
            }
            if !publicReferences.isEmpty {
                Section("Public references") {
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
                    .disabled(session.running || !canAcceptGuestProposals)
                Toggle("Allow guests to suggest pins", isOn: $acceptGuestPins)
                    .disabled(session.running || !canAcceptGuestProposals)
            } footer: {
                Text("Review each submission on this phone before adding it to Household.")
            }
            if let proposal = session.proposal {
                Section("Guest submission") {
                    switch proposal {
                    case let .note(note):
                        Text(note).textSelection(.enabled)
                        Button("Append to household notes") { accept(proposal) }
                    case let .pin(pin):
                        Text(pin.name).font(.headline)
                        Text(pin.coordinateText).textSelection(.enabled)
                        if !pin.note.isEmpty { Text(pin.note).textSelection(.enabled) }
                        Button("Add to saved pins") { accept(proposal) }
                    }
                    Button("Discard", role: .destructive) {
                        proposalError = nil
                        session.finishProposalReview()
                    }
                    if let proposalError { Text(proposalError).foregroundStyle(.secondary) }
                }
            }
            Section {
                switch session.state {
                case .ready(let link):
                    if session.foundDirections == false {
                        Text("No directions were available from installed routing data.").foregroundStyle(.secondary)
                    }
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
                    ProgressView("Preparing local share")
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
            let templates = HouseholdSharePublicReference.verified(from: NearbyPublicReference.catalogReferences)
            let starter = await Self.starterReferences()
            guard !Task.isCancelled else { return }
            publicReferences = templates + starter
        }
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) {
            if scenePhase == .background { session.stop() }
        }
    }

    private func accept(_ proposal: HouseholdGuestProposal) {
        do {
            switch proposal {
            case let .note(note): try appendGuestNote(note)
            case let .pin(pin): try saveGuestPin(pin)
            }
            proposalError = nil
            session.finishProposalReview()
        } catch {
            proposalError = error.localizedDescription
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

    static func starterReferences() async -> [HouseholdSharePublicReference] {
        let catalog = NearbyArchiveCatalog(downloads: .shared)
        guard let pin = catalog.pins.first(where: { $0.id.hasPrefix("tinfoil-kit-offline-starter") }),
              pin.byteCount <= 128 * 1024, let file = await catalog.source(pin),
              let data = try? Data(contentsOf: file), data.count == pin.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == pin.sha256,
              let archive = try? ZIMArchive(fileURL: file) else { return [] }

        func chapterText(_ chapter: String) -> (ZIMArchive.Resource, String)? {
            guard let resource = try? archive.resource(at: chapter + ".html"),
                  let html = String(data: resource.data, encoding: .utf8),
                  let document = try? SwiftSoup.parse(html),
                  let main = try? document.select("main").first(),
                  let text = try? main.text(), !text.isEmpty else { return nil }
            return (resource, text)
        }

        guard let (_, license) = chapterText("license") else { return [] }
        return ["earthquake-safety", "prepare-offline"].compactMap { chapter in
            guard let (resource, text) = chapterText(chapter) else { return nil }
            return HouseholdSharePublicReference(id: "offline-starter-" + chapter,
                                                 title: resource.title, text: text + "\n\n" + license)
        }
    }

    private var selectedReferences: [HouseholdSharePublicReference] {
        publicReferences.filter { selectedReferenceIDs.contains($0.id) }
    }

    private var startSharing: some View {
        Button("Start sharing", systemImage: "person.2") {
            proposalError = nil
            session.start(HouseholdSnapshot(
                notes: includeNotes ? snapshot.notes : "",
                home: includeHome ? snapshot.home : nil,
                pins: includePins ? snapshot.pins : []
            ), publicReferences: selectedReferences,
               includesDirections: includeHome && includePins && includeDirections,
               acceptsNotes: acceptGuestNotes && canAcceptGuestProposals,
               acceptsPins: acceptGuestPins && canAcceptGuestProposals)
        }
        .disabled(!((includeNotes && hasNotes) || (includeHome && snapshot.home != nil) ||
                    (includePins && !snapshot.pins.isEmpty) || !selectedReferences.isEmpty ||
                    ((acceptGuestNotes || acceptGuestPins) && canAcceptGuestProposals)))
    }
}

@MainActor
private final class HouseholdShareSession: ObservableObject {
    enum State {
        case idle, starting, replacing, ready(URL), message(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var proposal: HouseholdGuestProposal?
    @Published private(set) var foundDirections: Bool?
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

    func start(_ snapshot: HouseholdSnapshot, publicReferences: [HouseholdSharePublicReference],
               includesDirections: Bool, acceptsNotes: Bool, acceptsPins: Bool) {
        guard attempt == nil else { return }
        let id = UUID()
        attempt = id
        state = .starting
        startup = Task { [weak self] in
            let directions = includesDirections ? await HouseholdShareDirections.prepare(for: snapshot) : []
            guard let self, self.attempt == id, !Task.isCancelled else { return }
            self.foundDirections = includesDirections ? !directions.isEmpty : nil
            let page = HouseholdSharePage(snapshot: snapshot, publicReferences: publicReferences, directions: directions,
                                         acceptsNotes: acceptsNotes, acceptsPins: acceptsPins)
            self.publish(page, attempt: id)
        }
    }

    private func publish(_ page: HouseholdSharePage, attempt id: UUID) {
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

    func finishProposalReview() {
        proposal = nil
        server?.finishProposalReview()
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
        proposal = nil
        foundDirections = nil
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
        case let .proposal(incoming):
            proposal = incoming
        case let .failed(error):
            end(.message(error))
        case .expired:
            end(.message("The local link expired."))
        }
    }
}
