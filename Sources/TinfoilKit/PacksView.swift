import SwiftUI
import ZIMArchive

struct PacksView: View {
    @ObservedObject var downloads: PackDownloads
    let library: InstalledLibrary
    let onPublisherImport: () async -> Void
    @State private var language: PackCatalog.Language?
    @State private var cellularPack: PublishedPack?

    var body: some View {
        let downloadSize = downloads.downloadAllSizeEstimate
        let essentialsSize = downloads.essentialsSizeEstimate
        List {
            Section {
                Button {
                    downloads.startEssentials()
                } label: {
                    HStack {
                        Label("Download Essentials", systemImage: "arrow.down.circle")
                        if !downloads.restoring, essentialsSize > 0 {
                            Spacer()
                            Text(essentialsSize.formatted(.byteCount(style: .file)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(downloads.restoring || essentialsSize == 0)
                Button("Download all", systemImage: "arrow.down.circle") { downloads.startAll() }
                    .disabled(downloads.restoring || downloadSize == 0)
                if let error = downloads.downloadAllError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                } else if !downloads.restoring, downloadSize > 0 {
                    Text("Up to \(downloadSize.formatted(.byteCount(style: .file))) to download")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Bulk downloads use Wi-Fi. Download either complete English Wikipedia edition separately and resume cellular transfers individually.")
            }
            if let error = PackCatalog.loadError {
                Text(error).foregroundStyle(.secondary)
            }
            NavigationLink {
                KiwixDiscoveryView(library: library, onImport: onPublisherImport)
            } label: {
                Label("Find publisher books", systemImage: "magnifyingglass")
            }
            Picker("Language", selection: $language) {
                Text("All languages").tag(nil as PackCatalog.Language?)
                ForEach(PackCatalog.Language.allCases, id: \.self) { option in
                    Text(option.title).tag(Optional(option))
                }
            }
            ForEach(PackCatalog.Section.allCases, id: \.self) { section in
                let entries = PackCatalog.entries.filter {
                    $0.section == section && (language == nil || $0.language == language)
                }
                if !entries.isEmpty {
                    Section(section.title) {
                        ForEach(entries, content: row)
                    }
                }
            }
        }
        .navigationTitle("Content packs")
        .alert("Allow cellular data for this pack?", isPresented: Binding(
            get: { cellularPack != nil }, set: { if !$0 { cellularPack = nil } }
        ), presenting: cellularPack) { pack in
            Button("Allow cellular data") { downloads.start(pack, network: .cellularAllowed) }
            Button("Cancel", role: .cancel) {}
        } message: { pack in
            Text("\(pack.title) is about \(pack.sizeEstimate.formatted(.byteCount(style: .file))). Switching download modes may restart the transfer.")
        }
    }

    private func row(for entry: PackDownloads.CatalogEntry) -> some View {
        let pack = entry.pack
        return VStack(alignment: .leading, spacing: 8) {
            Text(pack.title).font(.headline)
            if let detail = entry.detail {
                Text(detail)
            }
            Text("\(pack.version) · \(pack.sizeEstimate.formatted(.byteCount(style: .file)))")
                .font(.footnote)
            if !entry.isDefault {
                Text("Earlier edition").font(.footnote).foregroundStyle(.secondary)
            }
            Text(pack.attribution)
                .font(.footnote)
            if let termsURL = entry.termsURL {
                Link("Content license", destination: termsURL).font(.footnote)
            }
            controls(for: pack)
        }
    }

    @ViewBuilder
    private func controls(for pack: PublishedPack) -> some View {
        switch downloads.statuses[pack.editionKey] {
        case let .downloading(fraction):
            let label = downloads.allowsCellular(for: pack) ? "Downloading · cellular allowed" : "Downloading"
            if let fraction {
                ProgressView(value: fraction) { Text(label) }
            } else {
                ProgressView(label)
            }
            Button("Pause") { downloads.pause(pack) }
        case .retrying:
            ProgressView("Waiting to retry download")
            Button("Pause") { downloads.pause(pack) }
        case .pausing:
            ProgressView("Pausing")
        case .paused:
            downloadControls("Resume download", pack: pack)
        case .verifying:
            ProgressView("Verifying archive")
        case .installed:
            Label("Installed", systemImage: "checkmark.circle")
        case let .failed(message):
            Text(message).font(.footnote).foregroundStyle(.secondary)
            downloadControls("Retry download", pack: pack)
        case nil:
            downloadControls("Download", pack: pack)
        }
    }

    private func downloadControls(_ title: String, pack: PublishedPack) -> some View {
        let resumesOnCellular = downloads.resumesOnCellular(for: pack)
        return HStack {
            Button(resumesOnCellular ? "\(title) · cellular allowed" : title) { downloads.start(pack) }
            Menu {
                if resumesOnCellular {
                    Button("Start over on Wi-Fi", systemImage: "wifi") { downloads.start(pack, network: .wifiOnly) }
                } else {
                    Button("Allow cellular data…", systemImage: "antenna.radiowaves.left.and.right") {
                        cellularPack = pack
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("Download options")
            }
        }
        .buttonStyle(.borderless)
        .disabled(downloads.restoring)
    }
}
