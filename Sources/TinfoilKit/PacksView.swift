import SwiftUI
import ZIMArchive

struct PacksView: View {
    @ObservedObject var downloads: PackDownloads

    var body: some View {
        List(PackDownloads.catalog) { pack in
            VStack(alignment: .leading, spacing: 8) {
                Text(pack.title).font(.headline)
                Text("\(pack.version) · About \(pack.sizeEstimate.formatted(.byteCount(style: .file)))")
                Text(pack.attribution)
                controls(for: pack)
            }
            .foregroundStyle(.primary)
        }
        .navigationTitle("Content packs")
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
