import SwiftUI

struct PortableLibraryView: View {
    @ObservedObject var downloads: PackDownloads
    @State private var choosingFolder = false
    @State private var folder: URL?
    @State private var matches: [PortableLibraryFolder.Match] = []
    @State private var selected: Set<String> = []
    @State private var scanTask: Task<Void, Never>?
    @State private var installTask: Task<Void, Never>?
    @State private var current: PortableLibraryFolder.Match?
    @State private var progress = 0.0
    @State private var issues: [String: String] = [:]
    @State private var status: String?

    private var chosen: [PortableLibraryFolder.Match] {
        matches.filter { selected.contains($0.id) && downloads.canInstallLocalCopy($0.pack) }
    }

    var body: some View {
        Form {
            Section {
                Button("Choose library folder", systemImage: "folder") { choosingFolder = true }
                    .disabled(scanTask != nil || installTask != nil || downloads.restoring)
                if let folder { Text(folder.lastPathComponent).foregroundStyle(.secondary) }
                if scanTask != nil { ProgressView("Checking catalog filenames") }
                if let status { Text(status).foregroundStyle(.secondary) }
            } footer: {
                Text("Choose a folder with ZIM files already available on this device or a connected drive. In desktop Tinfoil Kit, choose downloads/library.")
            }

            if !matches.isEmpty {
                Section {
                    ForEach(matches, content: packRow)
                    if let current {
                        if progress < 1 {
                            ProgressView(value: progress) { Text("Copying \(current.pack.title)") }
                        } else {
                            ProgressView("Verifying \(current.pack.title)")
                        }
                    }
                    if let installTask {
                        Button("Stop installing", role: .cancel) { installTask.cancel() }
                    } else {
                        Button("Install selected packs", systemImage: "square.and.arrow.down", action: install)
                            .disabled(chosen.isEmpty)
                    }
                } header: {
                    Text("Matching editions")
                } footer: {
                    Text("Selected files are copied and checked against the app’s publisher checksums. Completed packs stay installed if you stop. The originals stay in Files.")
                }
            }
        }
        .navigationTitle("Install from Files")
        .sheet(isPresented: $choosingFolder) {
            DocumentFolderPicker { url in
                choosingFolder = false
                if let url { scan(url) }
            }
        }
        .onDisappear {
            scanTask?.cancel()
            installTask?.cancel()
        }
    }

    private func packRow(_ match: PortableLibraryFolder.Match) -> some View {
        let available = downloads.canInstallLocalCopy(match.pack)
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { available && selected.contains(match.id) },
                set: { if $0 { selected.insert(match.id) } else { selected.remove(match.id) } }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(match.pack.title)
                    Text("\(match.pack.version) · \(match.bytes.formatted(.byteCount(style: .file)))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(!available || installTask != nil)
            if case .installed = downloads.statuses[match.id] {
                Label("Installed", systemImage: "checkmark.circle").font(.footnote)
            } else if let issue = issues[match.id] {
                Text(issue).font(.footnote).foregroundStyle(.secondary)
            } else if !available && current?.id != match.id {
                Text("An archive operation is pending.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func scan(_ url: URL) {
        let catalog = PackDownloads.catalog
        folder = url
        matches = []
        selected = []
        issues = [:]
        status = nil
        scanTask = Task {
            defer { scanTask = nil }
            let worker = Task.detached(priority: .userInitiated) {
                try PortableLibraryFolder.matchingPacks(in: url, catalog: catalog)
            }
            do {
                let found = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                matches = found
                selected = Set(found.filter { downloads.canInstallLocalCopy($0.pack) }.map(\.id))
                if found.isEmpty { status = "No matching catalog editions. For another ZIM, use Import from Files in Library." }
            } catch is CancellationError {
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func install() {
        guard installTask == nil, let folder else { return }
        let batch = chosen
        guard !batch.isEmpty else { return }
        status = nil
        installTask = Task {
            let accessed = folder.startAccessingSecurityScopedResource()
            defer {
                if accessed { folder.stopAccessingSecurityScopedResource() }
                current = nil
                installTask = nil
            }
            var succeeded = 0
            for match in batch {
                if Task.isCancelled { break }
                current = match
                progress = 0
                issues[match.id] = nil
                do {
                    try await downloads.installLocalCopy(match) { fraction in
                        Task { @MainActor in
                            if current?.id == match.id { progress = max(progress, fraction) }
                        }
                    }
                    succeeded += 1
                    selected.remove(match.id)
                } catch is CancellationError {
                    break
                } catch {
                    issues[match.id] = error.localizedDescription
                }
            }
            if Task.isCancelled {
                status = "Installation stopped. \(succeeded) of \(batch.count) selected packs installed."
            } else {
                status = "Installed \(succeeded) of \(batch.count) selected packs."
            }
        }
    }
}
