import SwiftUI

struct RegionalBundleDownloadView: View {
    let storage: RegionalBundleStorage
    let onInstall: (RegionalBundleStorage.Installed) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var downloader = RegionalBundleDownload()
    @State private var manifestURL = ""
    @State private var checksum = ""
    @State private var cellular = false
    @State private var manifest: RegionalBundleManifest?
    @State private var task: Task<Void, Never>?
    @State private var attempt: UUID?
    @State private var activity = ""
    @State private var fraction: Double?
    @State private var error: String?
    @State private var attemptedInstall = false
    @State private var cancelling = false

    var body: some View {
        NavigationStack {
            Form {
                if let manifest {
                    Section(manifest.region) {
                        LabeledContent("Edition", value: manifest.dataVersion)
                        LabeledContent("Download size",
                                       value: manifest.assets.downloadByteCount.formatted(.byteCount(style: .file)))
                        Link("Data source", destination: manifest.source)
                        Link("\(manifest.attribution) · \(manifest.license)", destination: manifest.licenseURL)
                    }
                    if let basemap = manifest.assets.basemap {
                        Section("Basemap") {
                            LabeledContent("Edition", value: basemap.dataVersion)
                            Link("Basemap source", destination: basemap.source)
                            Link("\(basemap.attribution) · \(basemap.license)", destination: basemap.licenseURL)
                        }
                    }
                } else {
                    Section {
                        TextField("HTTPS manifest URL", text: $manifestURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Manifest SHA-256", text: $checksum)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("Use an HTTPS link and a SHA-256 you received from a trusted source.")
                    }
                    .disabled(task != nil)
                }
                Toggle("Allow cellular data", isOn: $cellular)
                    .disabled(task != nil)

                if task != nil {
                    Section {
                        if let fraction {
                            ProgressView(activity, value: fraction)
                        } else {
                            ProgressView(activity)
                        }
                        Button(cancelling ? "Cancelling…" : "Cancel", role: .cancel) {
                            cancelling = true
                            task?.cancel()
                        }
                        .disabled(cancelling)
                    }
                } else {
                    Section {
                        if manifest == nil {
                            Button("Review download", action: loadManifest)
                                .disabled(manifestURL.isEmpty || checksum.isEmpty)
                        } else {
                            Button(attemptedInstall ? "Retry download" : "Download and install", action: install)
                            Button("Change manifest") {
                                manifest = nil
                                error = nil
                                attemptedInstall = false
                            }
                        }
                        if let error {
                            Text(error).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Download regional bundle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
                    .disabled(task != nil)
            }
        }
        .interactiveDismissDisabled(task != nil)
        .onDisappear { task?.cancel() }
    }

    private func loadManifest() {
        begin("Checking manifest") { _ in
            let source = try RegionalBundleDownloadSource(url: manifestURL, sha256: checksum)
            manifest = try await downloader.load(source, cellular: cellular)
        }
    }

    private func install() {
        attemptedInstall = true
        begin("Preparing download") { id in
            let installed = try await downloader.install(in: storage, cellular: cellular) { progress in
                Task { @MainActor in
                    guard attempt == id, !cancelling else { return }
                    switch progress {
                    case .receiving(let file, let received, let total):
                        switch file {
                        case "places.sqlite": activity = "Downloading place data"
                        case RegionalBundleManifest.basemapFilename: activity = "Downloading basemap"
                        default: activity = "Downloading routing graph"
                        }
                        fraction = Double(received) / Double(total)
                    case .installing:
                        activity = "Verifying and installing"
                        fraction = nil
                    }
                }
            }
            await onInstall(installed)
            dismiss()
        }
    }

    private func begin(_ label: String, operation: @escaping @MainActor (UUID) async throws -> Void) {
        guard task == nil else { return }
        let id = UUID()
        attempt = id
        error = nil
        activity = label
        fraction = nil
        task = Task { @MainActor in
            defer {
                attempt = nil
                task = nil
                cancelling = false
            }
            do { try await operation(id) }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }
}
