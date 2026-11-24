import SwiftUI

struct InstalledBasemapsView: View {
    let storage: MapStorage
    let activeMapID: OfflineMap.ID?
    let onSelect: (OfflineMap?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var maps: [OfflineMap] = []
    @State private var pendingRemoval: OfflineMap?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if maps.isEmpty { Text("No basemaps installed").foregroundStyle(.secondary) }
                ForEach(maps) { map in
                    Button {
                        Task { await show(map) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(map.title)
                                Text(coverage(map))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if map.id == activeMapID {
                                Image(systemName: "checkmark").accessibilityLabel("Selected")
                            }
                        }
                    }
                    .swipeActions {
                        if !map.isBundled {
                            Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = map }
                        }
                    }
                }
            }
            .navigationTitle("Installed basemaps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { await reload() }
            .confirmationDialog("Remove basemap?", isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
            ), presenting: pendingRemoval) { map in
                Button("Remove \(map.title)", role: .destructive) { Task { await remove(map) } }
            } message: { map in
                Text("Remove the imported basemap \(map.title) from this phone?")
            }
            .alert("Basemap error", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
        }
    }

    private func show(_ map: OfflineMap) async {
        do {
            onSelect(try await storage.selectMap(map.id))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ map: OfflineMap) async {
        do {
            try await storage.removeMap(map.id)
            if activeMapID == map.id {
                onSelect(try await storage.current())
                dismiss()
            } else {
                await reload()
            }
        } catch { self.error = error.localizedDescription }
    }

    private func reload() async {
        do { maps = try await storage.installedMaps() }
        catch { self.error = error.localizedDescription }
    }

    private func coverage(_ map: OfflineMap) -> String {
        let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
        return "\(map.minLatitude.formatted(number))…\(map.maxLatitude.formatted(number)) lat · "
            + "\(map.minLongitude.formatted(number))…\(map.maxLongitude.formatted(number)) lon"
    }
}
