import SwiftUI

struct InstalledPlaceDataView: View {
    let storage: RegionalPlaceStorage
    @Binding var regions: [RegionalPlaceStorage.Installed]
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: RegionalPlaceStorage.Installed?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if regions.isEmpty { Text("No regional place data installed").foregroundStyle(.secondary) }
                ForEach(regions) { region in
                    Section(region.metadata.region) {
                        let metadata = region.metadata
                        LabeledContent("Mapped places", value: metadata.placeCount.formatted())
                        if let version = metadata.dataVersion { LabeledContent("Edition", value: version) }
                        Link("Data source", destination: metadata.source)
                        Link("\(metadata.attribution) · \(metadata.license)", destination: metadata.licenseURL)
                        if region.bundleID == nil {
                            Button("Remove regional place data", role: .destructive) { pendingRemoval = region }
                        } else {
                            Text("Managed in Installed regional bundles.").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Installed place data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Remove regional place data?", isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
            ), presenting: pendingRemoval) { region in
                Button("Remove \(region.metadata.region)", role: .destructive) { Task { await remove(region) } }
            }
            .alert("Place data error", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
        }
    }

    private func remove(_ region: RegionalPlaceStorage.Installed) async {
        do {
            try await storage.remove(region.id)
            regions.removeAll { $0.id == region.id }
        } catch { self.error = error.localizedDescription }
    }
}
