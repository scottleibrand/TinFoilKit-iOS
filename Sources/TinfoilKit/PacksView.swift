import SwiftUI
import ZIMArchive

struct PacksView: View {
    @ObservedObject var downloads: PackDownloads
    @State private var language: PackCatalog.Language?

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
                Text("Downloads use Wi-Fi. Bulk downloads include the current editions.")
            }
            if let error = PackCatalog.loadError {
                Text(error).foregroundStyle(.secondary)
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
            if let fraction {
                ProgressView(value: fraction) { Text("Downloading") }
            } else {
                ProgressView("Downloading")
            }
            Button("Pause") { downloads.pause(pack) }
        case .pausing:
            ProgressView("Pausing")
        case .paused:
            Button("Resume download") { downloads.start(pack) }
        case .verifying:
            ProgressView("Verifying archive")
        case .installed:
            Label("Installed", systemImage: "checkmark.circle")
        case let .failed(message):
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Button("Retry download") { downloads.start(pack) }
        case nil:
            Button("Download") { downloads.start(pack) }
                .disabled(downloads.restoring)
        }
    }
}
