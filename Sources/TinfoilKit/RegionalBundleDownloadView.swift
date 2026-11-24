import SwiftUI

struct RegionalBundleDownloadView: View {
    let storage: RegionalBundleStorage
    let onInstall: (RegionalBundleStorage.Installed) async -> Void
    @Environment(\.dismiss) private var dismiss
    private let downloader = RegionalBundleDownload.shared
    @State private var manifestURL = ""
    @State private var checksum = ""
    @State private var cellular = false
    @State private var pending: RegionalBundleDownload.Pending?
    @State private var task: Task<Void, Never>?
    @State private var attempt: UUID?
    @State private var activity = ""
    @State private var fraction: Double?
    @State private var error: String?
    @State private var attemptedInstall = false
    @State private var cancelling = false
    @State private var restoring = true
    @State private var invalidPending = false
    @State private var waitingForTransfer = false
    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            Form {
                if restoring {
                    ProgressView("Checking for a pending download")
                } else if let pending {
                    let manifest = pending.manifest
                    Section(manifest.region) {
                        LabeledContent("Edition", value: manifest.dataVersion)
                        LabeledContent("Download size",
                                       value: manifest.assets.downloadByteCount.formatted(.byteCount(style: .file)))
                        Link("Data source", destination: manifest.source)
                        Link("\(manifest.attribution) · \(manifest.license)", destination: manifest.licenseURL)
                        LabeledContent("Network", value: pending.cellular ? "Wi-Fi and cellular" : "Wi-Fi only")
                    }
                    if let basemap = manifest.assets.basemap {
                        Section("Basemap") {
                            LabeledContent("Edition", value: basemap.dataVersion)
                            Link("Basemap source", destination: basemap.source)
                            Link("\(basemap.attribution) · \(basemap.license)", destination: basemap.licenseURL)
                        }
                    }
                } else if !invalidPending, !waitingForTransfer {
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
                    Toggle("Allow cellular data", isOn: $cellular)
                        .disabled(task != nil)
                }

                if task != nil {
                    Section {
                        if let fraction {
                            ProgressView(activity, value: fraction)
                        } else {
                            ProgressView(activity)
                        }
                        Button(cancelling ? "Stopping…" : (pending == nil ? "Cancel" : "Pause download"), role: .cancel) {
                            cancelling = true
                            task?.cancel()
                        }
                        .disabled(cancelling)
                    }
                } else if !restoring {
                    Section {
                        if waitingForTransfer {
                            Button("Check again") { Task { await restore() } }
                        } else if invalidPending {
                            Button("Discard download", role: .destructive) { confirmingDiscard = true }
                        } else if pending == nil {
                            Button("Review download", action: loadManifest)
                                .disabled(manifestURL.isEmpty || checksum.isEmpty)
                        } else {
                            Button(attemptedInstall ? "Resume download" : "Download and install", action: install)
                            Button("Discard download", role: .destructive) { confirmingDiscard = true }
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
            .confirmationDialog("Discard regional download?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard download", role: .destructive, action: discard)
            } message: {
                Text("Saved download files will be removed.")
            }
        }
        .task { await restore() }
        .interactiveDismissDisabled(task != nil)
        .onDisappear { task?.cancel() }
    }

    private func loadManifest() {
        begin("Checking manifest") { _ in
            let source = try RegionalBundleDownloadSource(url: manifestURL, sha256: checksum)
            pending = try await downloader.load(source, cellular: cellular)
        }
    }

    private func restore() async {
        restoring = true
        waitingForTransfer = false
        error = nil
        defer { restoring = false }
        do {
            pending = try await downloader.pending()
            attemptedInstall = pending?.started == true
        } catch is CancellationError {
        } catch RegionalBundleDownloadError.busy {
            waitingForTransfer = true
            error = "The previous regional transfer is finishing."
        } catch {
            invalidPending = true
            self.error = error.localizedDescription
        }
    }

    private func discard() {
        begin("Discarding download") { _ in
            try await downloader.discard()
            pending = nil
            invalidPending = false
            attemptedInstall = false
        }
    }

    private func install() {
        attemptedInstall = true
        begin("Preparing download") { id in
            let installed = try await downloader.install(in: storage) { progress in
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
            await Task { await onInstall(installed) }.value
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
