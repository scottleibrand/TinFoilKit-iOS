import SwiftUI
import UIKit

struct NearbyView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var nearby: NearbyLifecycle
    @EnvironmentObject private var discovery: NearbyDiscovery
    @EnvironmentObject private var notifications: NearbyResumeNotifications
    @State private var screenID = UUID()

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
                Text("Match the code shown on the other device to its entry below.")
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
            Section {
                Toggle("Sync public references", isOn: Binding(
                    get: { nearby.publicSyncEnabled },
                    set: { nearby.setPublicSyncEnabled($0) }
                ))
                if nearby.publicSyncEnabled {
                    Toggle("Notify me about interrupted downloads", isOn: Binding(
                        get: { notifications.isEnabled },
                        set: { enabled in Task { await notifications.setEnabled(enabled) } }
                    ))
                    if notifications.authorizationUnavailable {
                        Button("Open notification settings") {
                            if let settings = URL(string: UIApplication.openNotificationSettingsURLString) {
                                openURL(settings)
                            }
                        }
                    }
                }
                if let text = discovery.publicReferenceText {
                    NavigationLink(NearbyPublicReference.title) {
                        ScrollView {
                            Text(text).frame(maxWidth: .infinity, alignment: .leading).padding()
                        }
                        .navigationTitle(NearbyPublicReference.title)
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            } footer: {
                Text("Tinfoil Kit syncs verified public references while you use the app. An active transfer can finish if you switch apps.")
            }
        }
        .navigationTitle("Nearby")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nearby.setNearbyScreen(screenID, visible: true) }
        .onDisappear { nearby.setNearbyScreen(screenID, visible: false) }
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
