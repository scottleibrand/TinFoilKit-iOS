import SwiftUI
import UniformTypeIdentifiers

struct WaterServiceAreaView: View {
    let home: HouseholdPlace?
    var onSelect: ((WaterServiceProvider) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var installed: Bool?
    @State private var choosingFile = false
    @State private var confirmingRemoval = false
    @State private var activity: Activity?
    @State private var lookup: Lookup?
    @State private var error: String?

    private let store = WaterServiceAreaStore.standard

    private enum Activity: String {
        case importing = "Verifying water service area data"
        case lookingUp = "Checking mapped providers at Home"
        case removing = "Removing water service area data"
    }

    private struct Lookup {
        let home: HouseholdPlace
        let providers: [WaterServiceProvider]
    }

    var body: some View {
        NavigationStack {
            Form {
                dataset
                homeLookup
                if let activity {
                    Section { ProgressView(activity.rawValue) }
                }
                Section("Source") {
                    Link("Washington State Department of Health, Office of Drinking Water",
                         destination: WaterServiceAreaStore.source)
                    LabeledContent("Verified edition", value: WaterServiceAreaStore.edition)
                }
            }
            .navigationTitle("Water service areas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(activity == .importing || activity == .removing)
                }
            }
        }
        .task(id: home) {
            let hasDataset = await store.isInstalled()
            guard !Task.isCancelled else { return }
            installed = hasDataset
            if hasDataset, onSelect != nil { await findProviders() }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [UTType(filenameExtension: "geojson") ?? .json, .json]) { result in
            Task { await importDataset(result) }
        }
        .confirmationDialog("Remove water service area data?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove imported data", role: .destructive) { Task { await removeDataset() } }
        }
        .alert("Water service area error", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var dataset: some View {
        Section {
            if let installed {
                Text(installed ? "Seattle-area provider map installed" : "No provider map installed")
                    .foregroundStyle(.secondary)
                Button("Import from Files", systemImage: "square.and.arrow.down") { choosingFile = true }
                if installed {
                    Button("Remove provider map", role: .destructive) { confirmingRemoval = true }
                }
            } else {
                ProgressView("Checking installed data")
            }
        } header: {
            Text("Offline provider map")
        } footer: {
            Text("Choose the verified Seattle-area GeoJSON file for the edition below.")
        }
        .disabled(activity != nil)
    }

    private var homeLookup: some View {
        Section {
            if home == nil {
                Text("Set Home in Map to look up your mapped providers.").foregroundStyle(.secondary)
            } else if installed == true {
                Button("Look up mapped providers at Home", systemImage: "magnifyingglass") {
                    Task { await findProviders() }
                }
                if let lookup, lookup.home == home {
                    if lookup.providers.isEmpty {
                        Text("No mapped provider was found at Home in this edition.").foregroundStyle(.secondary)
                    }
                    ForEach(lookup.providers) { provider in
                        if let onSelect {
                            Button {
                                onSelect(provider)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    providerRow(provider)
                                    Text("Use this provider in Ask").font(.caption)
                                }
                            }
                        } else {
                            providerRow(provider)
                        }
                    }
                }
            } else if installed == false {
                Text("Import the provider map to check Home.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Home lookup")
        } footer: {
            Text("Lookup runs on this device. Map matches describe published service boundaries. Coverage can overlap or be incomplete. Check your utility for current outage status.")
        }
        .disabled(activity != nil)
    }

    private func providerRow(_ provider: WaterServiceProvider) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(provider.name).font(.headline)
            if !provider.county.isEmpty {
                Text(provider.county).font(.subheadline).foregroundStyle(.secondary)
            }
            if let updated = provider.updatedAt, !updated.isEmpty {
                Text("Map record updated \(updated)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func importDataset(_ result: Result<URL, Error>) async {
        guard activity == nil else { return }
        activity = .importing
        defer { activity = nil }
        do {
            try await store.install(from: result.get())
            installed = true
            lookup = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeDataset() async {
        guard activity == nil else { return }
        activity = .removing
        defer { activity = nil }
        do {
            try await store.remove()
            installed = false
            lookup = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func findProviders() async {
        guard activity == nil, let home else { return }
        activity = .lookingUp
        lookup = nil
        defer { activity = nil }
        do {
            let providers = try await store.providers(latitude: home.latitude, longitude: home.longitude)
            try Task.checkCancellation()
            lookup = Lookup(home: home, providers: providers)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
