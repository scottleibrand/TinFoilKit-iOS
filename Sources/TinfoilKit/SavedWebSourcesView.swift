import SwiftUI

struct SavedWebSourcesView: View {
    var onChange: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var sources: [OnlineAskSavedSource] = []
    @State private var requestedURL: URL?
    @State private var status: String?
    @FocusState private var editingLink: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Source URL", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($editingLink)
                        .disabled(requestedURL != nil)
                    Button("Save for offline use", systemImage: "arrow.down.document") { requestSave() }
                        .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || requestedURL != nil)
                    if requestedURL != nil {
                        ProgressView("Saving source")
                        Button("Cancel download", role: .cancel) { requestedURL = nil }
                    }
                    if let status { Text(status).foregroundStyle(.secondary) }
                } header: {
                    Text("Add a source")
                } footer: {
                    Text("Paste a public article or PDF link. Saved text stays on this phone and can appear in Ask results.")
                }
                Section("Saved sources") {
                    if sources.isEmpty { Text("No saved web sources").foregroundStyle(.secondary) }
                    ForEach(sources) { source in
                        NavigationLink {
                            OnlineAskSourceView(source: source)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(source.citation.title)
                                if let host = (source.resolvedURL ?? source.id).host {
                                    Text(host).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                Task { await remove(source) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Saved web sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { await reload() }
            .task(id: requestedURL) { if let requestedURL { await save(requestedURL) } }
        }
    }

    private func requestSave() {
        var components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines))
        components?.fragment = nil
        guard let url = components?.url, OnlineSourceArchiver.isPublicWebURL(url) else {
            status = "Enter a public web address starting with https:// or http://."
            return
        }
        editingLink = false
        status = nil
        requestedURL = url
    }

    private func save(_ url: URL) async {
        defer { if !Task.isCancelled { requestedURL = nil } }
        do {
            let citation = OnlineAskCitation(url: url, title: "", excerpt: nil)
            let captured = try await OnlineSourceArchiver.capture([citation])
            try Task.checkCancellation()
            guard let source = captured.first, source.text != nil else {
                status = captured.first?.note ?? "The source could not be saved."
                return
            }
            try await OnlineAskCache.shared.saveWebSource(source)
            try Task.checkCancellation()
            link = ""
            status = "Saved for offline use."
            onChange()
            await reload()
        } catch is CancellationError {
        } catch {
            status = error.localizedDescription
        }
    }

    private func remove(_ source: OnlineAskSavedSource) async {
        do {
            try await OnlineAskCache.shared.removeWebSource(source.id)
            onChange()
            await reload()
        } catch {
            status = error.localizedDescription
        }
    }

    private func reload() async {
        do {
            let saved = try await OnlineAskCache.shared.webSources()
            try Task.checkCancellation()
            sources = saved.sorted { $0.citation.title.localizedStandardCompare($1.citation.title) == .orderedAscending }
        } catch is CancellationError {
        } catch {
            status = error.localizedDescription
        }
    }
}
