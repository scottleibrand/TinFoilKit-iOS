import SwiftUI
import UIKit

struct NearbyView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var discovery = NearbyDiscovery()
    @State private var screenIsOpen = false

    var body: some View {
        List {
            Section {
                if let id = discovery.localID {
                    LabeledContent("Your nearby code") {
                        Text(Self.code(for: id)).font(.body.monospaced())
                    }
                }
                discoveryStatus
            } footer: {
                Text("Keep this screen open on both devices. Match the code shown on the other device to its entry below.")
            }

            if !discovery.peers.isEmpty {
                Section("Nearby devices") {
                    ForEach(discovery.peers, id: \.id) { peer in
                        Label {
                            Text(Self.code(for: peer.id)).font(.body.monospaced())
                        } icon: {
                            Image(systemName: "iphone")
                        }
                    }
                }
            }
        }
        .navigationTitle("Nearby")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            screenIsOpen = true
            if scenePhase == .active { discovery.start() }
        }
        .onDisappear {
            screenIsOpen = false
            discovery.stop()
        }
        .onChange(of: scenePhase) {
            guard screenIsOpen else { return }
            if scenePhase == .active {
                discovery.start()
            } else if scenePhase == .background {
                discovery.stop()
            }
        }
    }

    @ViewBuilder
    private var discoveryStatus: some View {
        switch discovery.state {
        case .idle, .starting:
            ProgressView("Starting nearby discovery")
        case .discovering:
            Label(discovery.peers.isEmpty ? "Looking for nearby devices" : "Nearby discovery is active",
                  systemImage: "dot.radiowaves.left.and.right")
        case let .waiting(message):
            Label(message, systemImage: "wifi.exclamationmark")
            Button("Retry") { discovery.rotate() }
        case .permissionDenied:
            Label("Allow local network access to find nearby devices.", systemImage: "wifi.exclamationmark")
            Button("Open Settings") {
                if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
            }
            Button("Retry") { discovery.rotate() }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
            Button("Retry") { discovery.rotate() }
        }
    }

    private static func code(for id: String) -> String {
        let code = id.prefix(8).uppercased()
        return String(code.prefix(4)) + "-" + String(code.suffix(4))
    }
}
