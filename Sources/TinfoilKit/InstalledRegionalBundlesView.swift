import SwiftUI

struct InstalledRegionalBundlesView: View {
    let storage: RegionalBundleStorage
    let onRemove: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bundles: [RegionalBundleStorage.Installed]?
    @State private var pendingRemoval: RegionalBundleStorage.Installed?
    @State private var removing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let bundles {
                    if bundles.isEmpty {
                        Text("No regional bundles installed").foregroundStyle(.secondary)
                    }
                    ForEach(bundles) { installed in
                        let manifest = installed.manifest
                        Section(manifest.region) {
                            LabeledContent("Edition", value: manifest.dataVersion)
                            LabeledContent("Place data", value: manifest.assets.places.byteCount.formatted(.byteCount(style: .file)))
                            LabeledContent("Routing", value: manifest.assets.routing.byteCount.formatted(.byteCount(style: .file)))
                            Link("Data source", destination: manifest.source)
                            Link("\(manifest.attribution) · \(manifest.license)", destination: manifest.licenseURL)
                            if let basemap = manifest.assets.basemap {
                                LabeledContent("Basemap", value: basemap.byteCount.formatted(.byteCount(style: .file)))
                                LabeledContent("Basemap edition", value: basemap.dataVersion)
                                Link("Basemap source", destination: basemap.source)
                                Link("\(basemap.attribution) · \(basemap.license)", destination: basemap.licenseURL)
                            }
                            Button("Remove regional bundle", role: .destructive) { pendingRemoval = installed }
                        }
                    }
                } else {
                    ProgressView("Loading regional bundles")
                }
            }
            .disabled(removing)
            .navigationTitle("Installed regional bundles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if removing {
                    ProgressView("Removing bundle")
                } else {
                    Button("Done") { dismiss() }
                }
            }
            .task { await reload() }
            .confirmationDialog("Remove regional bundle?", isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
            ), presenting: pendingRemoval) { installed in
                Button("Remove \(installed.manifest.region)", role: .destructive) {
                    Task { await remove(installed) }
                }
            } message: { installed in
                if installed.manifest.assets.basemap != nil {
                    Text("This removes the bundle's basemap, offline place data, and routing graph.")
                } else {
                    Text("This removes the bundle's offline place data and routing graph.")
                }
            }
            .alert("Regional bundle error", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled(removing)
    }

    private func reload() async {
        do { bundles = try await storage.installedBundles() }
        catch {
            bundles = []
            self.error = error.localizedDescription
        }
    }

    private func remove(_ installed: RegionalBundleStorage.Installed) async {
        guard !removing else { return }
        removing = true
        defer { removing = false }
        do {
            try await storage.remove(installed.id)
            bundles?.removeAll { $0.id == installed.id }
            try await onRemove()
        } catch { self.error = error.localizedDescription }
    }
}
