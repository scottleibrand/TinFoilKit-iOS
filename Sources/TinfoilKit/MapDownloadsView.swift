import SwiftUI

struct MapDownloadsView: View {
    @ObservedObject var exploration: MapExploration
    @Environment(\.dismiss) private var dismiss
    @State private var bytes: Int64?
    @State private var confirmingClear = false
    @State private var clearing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Automatic downloads", selection: Binding(
                        get: { exploration.policy }, set: exploration.setPolicy
                    )) {
                        ForEach(MapDownloadPolicy.allCases) { policy in Text(policy.title).tag(policy) }
                    }
                    Link("Map data provider", destination: URL(string: "https://source.coop/protomaps/openstreetmap")!)
                } footer: {
                    Text("Map tile requests reveal the areas you view to the map data provider. Saved tiles stay available offline when automatic downloads are off.")
                }
                Section {
                    LabeledContent("Saved tiles", value: bytes?.formatted(.byteCount(style: .file)) ?? "Checking…")
                    Button("Clear saved tiles", role: .destructive) { confirmingClear = true }
                } footer: {
                    Text("Imported and bundled maps are stored separately.")
                }
            }
            .disabled(clearing)
            .navigationTitle("Map downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { await measure() }
            .confirmationDialog("Clear saved tiles and turn off automatic downloads?", isPresented: $confirmingClear,
                                titleVisibility: .visible) {
                Button("Clear saved tiles", role: .destructive) { Task { await clear() } }
            }
            .alert("Map downloads", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
        }
    }

    private func measure() async {
        do { bytes = try await exploration.savedBytes() }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }

    private func clear() async {
        clearing = true
        defer { clearing = false }
        do {
            try await exploration.clearSavedTiles()
            await measure()
        } catch { self.error = error.localizedDescription }
    }
}
