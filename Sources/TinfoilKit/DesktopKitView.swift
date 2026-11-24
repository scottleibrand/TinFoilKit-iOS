import SafariServices
import SwiftUI

struct DesktopKitView: View {
    @State private var address = ""
    @State private var connection: DesktopConnection?
    @State private var invalidAddress = false

    var body: some View {
        Form {
            Section {
                TextField("Desktop invitation link", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                Button("Open desktop kit") {
                    if let url = Self.localURL(from: address) {
                        connection = DesktopConnection(url: url)
                    } else {
                        invalidAddress = true
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("On the computer running Tinfoil Kit, open Share with family. Paste its invitation link while connected to the same Wi-Fi.")
            }
        }
        .navigationTitle("Desktop kit")
        .alert("Check the invitation link", isPresented: $invalidAddress) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enter a Tinfoil Kit link for a private home-network address.")
        }
        .sheet(item: $connection) { connection in
            DesktopBrowser(url: connection.url)
                .ignoresSafeArea()
        }
    }

    private static func localURL(from address: String) -> URL? {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil else { return nil }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = components.compactMap { UInt8($0) }
        let privateIP = components.count == 4 && octets.count == 4 && (
            octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 100 && (64...127).contains(octets[1]))
        )
        let localName = [".local", ".lan", ".home", ".internal", ".home.arpa"].contains { host.hasSuffix($0) }
        return privateIP || localName ? parts.url : nil
    }

    private struct DesktopConnection: Identifiable {
        let id = UUID()
        let url: URL
    }
}

private struct DesktopBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
