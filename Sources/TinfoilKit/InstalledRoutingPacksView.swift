import SwiftUI

struct InstalledRoutingPacksView: View {
    let storage: RegionalRouteStore
    @Binding var packs: [RegionalRouteStore.Installed]
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: RegionalRouteStore.Installed?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if packs.isEmpty { Text("No routing packs installed").foregroundStyle(.secondary) }
                ForEach(packs) { installed in
                    let pack = installed.pack
                    Section(pack.region) {
                        LabeledContent("Edition", value: pack.dataVersion)
                        LabeledContent("Size", value: pack.graphByteCount.formatted(.byteCount(style: .file)))
                        Text(coverage(pack.bounds)).font(.caption).foregroundStyle(.secondary)
                        Link("Data source", destination: pack.source)
                        Link("\(pack.attribution) · \(pack.license)", destination: pack.licenseURL)
                        Button("Remove routing pack", role: .destructive) { pendingRemoval = installed }
                    }
                }
            }
            .navigationTitle("Installed routing packs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Remove routing pack?", isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
            ), presenting: pendingRemoval) { installed in
                Button("Remove \(installed.pack.region)", role: .destructive) { Task { await remove(installed) } }
            }
            .alert("Routing pack error", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
        }
    }

    private func remove(_ installed: RegionalRouteStore.Installed) async {
        do {
            try await storage.remove(installed.id)
            packs.removeAll { $0.id == installed.id }
        } catch { self.error = error.localizedDescription }
    }

    private func coverage(_ bounds: RoutingPack.Bounds) -> String {
        let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
        return "\(bounds.south.formatted(number))…\(bounds.north.formatted(number)) lat · "
            + "\(bounds.west.formatted(number))…\(bounds.east.formatted(number)) lon"
    }
}
