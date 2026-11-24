import SwiftUI
import WebKit

struct OnlineAskView: View {
    let question: String?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var configured: Set<OnlineAskProvider> = []
    @State private var editing: OnlineAskProvider?
    @State private var key = ""
    @State private var pending: OnlineAskProvider?
    @State private var result: OnlineAskSavedAnswer?
    @State private var searchEntryPoint: String?
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let question {
                    Section("Question to send") { Text(question) }
                    Section {
                        ForEach(OnlineAskProvider.allCases) { provider in
                            Button {
                                if configured.contains(provider) {
                                    pending = provider
                                } else {
                                    edit(provider)
                                }
                            } label: {
                                Label(configured.contains(provider) ? "Ask \(provider.title)" : "Set up \(provider.title)",
                                      systemImage: "globe")
                            }
                            .disabled(pending != nil)
                        }
                    } footer: {
                        Text("Only this question is sent to the selected provider. An internet connection and a provider API key are required. Provider charges may apply.")
                    }
                }
                if let status { Section { Text(status).foregroundStyle(.secondary) } }
                if let error { Section { Text(error).foregroundStyle(.secondary) } }
                if let result {
                    OnlineAskAnswerSections(entry: result)
                    if let searchEntryPoint {
                        Section("Google Search suggestions") {
                            OnlineGoogleSuggestions(html: searchEntryPoint).frame(minHeight: 100)
                        }
                    }
                }
                Section {
                    ForEach(OnlineAskProvider.allCases) { provider in
                        Button(configured.contains(provider) ? "Manage \(provider.title) key" : "Add \(provider.title) key") {
                            edit(provider)
                        }
                        .disabled(pending != nil)
                    }
                } header: {
                    Text("Provider API keys")
                } footer: {
                    Text("Keys stay in this device’s Keychain.")
                }
            }
            .navigationTitle(question == nil ? "Online providers" : "Ask online")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { refreshKeys() }
            .task(id: pending) {
                if let provider = pending { await ask(provider) }
            }
            .sheet(item: $editing) { provider in
                NavigationStack {
                    Form {
                        SecureField("API key", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if configured.contains(provider) {
                            Button("Remove key", role: .destructive) { saveKey("", for: provider) }
                        }
                    }
                    .navigationTitle("\(provider.title) API key")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                key = ""
                                editing = nil
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { saveKey(key, for: provider) }
                                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func refreshKeys() {
        configured = Set(OnlineAskProvider.allCases.filter { (try? OnlineAskKeys.key(for: $0)) != nil })
    }

    private func edit(_ provider: OnlineAskProvider) {
        key = ""
        editing = provider
    }

    private func saveKey(_ value: String, for provider: OnlineAskProvider) {
        do {
            try OnlineAskKeys.save(value, for: provider)
            refreshKeys()
        } catch {
            self.error = error.localizedDescription
        }
        key = ""
        editing = nil
    }

    private func ask(_ provider: OnlineAskProvider) async {
        guard let question else { return }
        defer { pending = nil }
        result = nil
        searchEntryPoint = nil
        error = nil
        status = "Waiting for \(provider.title)"
        do {
            guard let key = try OnlineAskKeys.key(for: provider) else {
                status = nil
                edit(provider)
                return
            }
            let reply = try await OnlineAskClient.ask(question, provider: provider, apiKey: key)
            try Task.checkCancellation()
            let initial = reply.citations.map {
                OnlineAskSavedSource(citation: $0, resolvedURL: nil, text: nil, note: nil)
            }
            let entry = OnlineAskSavedAnswer(provider: provider, question: question, answer: reply.answer, sources: initial)
            result = entry
            searchEntryPoint = reply.searchEntryPointHTML
            guard reply.cacheAllowed else {
                status = "This provider’s grounded response is available for this session."
                return
            }
            status = "Saving sources for offline use"
            try await OnlineAskCache.shared.save(entry)
            onSaved()
            let capture = Task.detached(priority: .utility) {
                let sources = try await OnlineSourceArchiver.capture(reply.citations)
                let enriched = OnlineAskSavedAnswer(id: entry.id, savedAt: entry.savedAt, provider: provider,
                                                   question: question, answer: reply.answer, sources: sources)
                try await OnlineAskCache.shared.save(enriched)
                return enriched
            }
            let archived = try await capture.value
            try Task.checkCancellation()
            result = archived
            onSaved()
            let readable = archived.sources.filter { $0.text != nil }.count
            status = "Saved offline · \(readable) of \(archived.sources.count) sources have readable copies"
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            status = nil
            self.error = error.localizedDescription
        }
    }
}

struct OnlineAskSavedAnswerView: View {
    let entry: OnlineAskSavedAnswer

    var body: some View {
        List { OnlineAskAnswerSections(entry: entry) }
            .navigationTitle("Saved online answer")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct OnlineAskAnswerSections: View {
    let entry: OnlineAskSavedAnswer
    @State private var selected: OnlineAskSavedSource?

    var body: some View {
        Section {
            Text(formattedAnswer)
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    if entry.provider == .gemini {
                        return OnlineSourceArchiver.isPublicWebURL(url) ? .systemAction : .discarded
                    }
                    if let source = entry.sources.first(where: { $0.citation.url == url || $0.resolvedURL == url }) {
                        selected = source
                        return .handled
                    }
                    return .discarded
                })
                .sheet(item: $selected) { source in
                    NavigationStack { OnlineAskSourceView(source: source, dismissible: true) }
                }
        } header: {
            Text(entry.provider.title)
        } footer: {
            Text(entry.savedAt.formatted(date: .abbreviated, time: .shortened))
        }
        if !entry.sources.isEmpty {
            Section("Sources") {
                ForEach(entry.sources) { source in
                    if entry.provider == .gemini, OnlineSourceArchiver.isPublicWebURL(source.citation.url) {
                        Link(source.citation.title, destination: source.citation.url)
                    } else {
                        NavigationLink { OnlineAskSourceView(source: source) } label: {
                            VStack(alignment: .leading) {
                                Text(source.citation.title)
                                Text(source.text == nil ? "Citation details" : "Saved readable text")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var formattedAnswer: AttributedString {
        (try? AttributedString(markdown: entry.answer,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(entry.answer)
    }
}

struct OnlineAskSourceView: View {
    let source: OnlineAskSavedSource
    var dismissible = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(source.citation.title).font(.headline).textSelection(.enabled)
                if let excerpt = source.citation.excerpt { Text(excerpt).textSelection(.enabled) }
                if let text = source.text { Text(text).textSelection(.enabled) }
                if let note = source.note { Text(note).foregroundStyle(.secondary) }
                let url = source.resolvedURL ?? source.citation.url
                if OnlineSourceArchiver.isPublicWebURL(url) {
                    Link("Open original source online", destination: url)
                } else {
                    Text(url.absoluteString).font(.caption).textSelection(.enabled)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if dismissible { Button("Done") { dismiss() } } }
    }
}

private struct OnlineGoogleSuggestions: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.loadHTMLString("""
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: https://www.google.com https://www.gstatic.com">
            \(html)
            """, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            if navigationAction.navigationType == .linkActivated {
                if let url, url.scheme == "https", url.host == "www.google.com" || url.host == "google.com" {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(url?.scheme == "about" ? .allow : .cancel)
            }
        }
    }
}
