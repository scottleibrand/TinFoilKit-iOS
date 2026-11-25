import SwiftUI
import UniformTypeIdentifiers
import ZIMArchive

struct KiwixDiscoveryView: View {
    let library: InstalledLibrary
    let onImport: () async -> Void
    @State private var query = ""
    @State private var books: [KiwixCatalog.Book]?
    @State private var searchTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                TextField("Book title or topic", text: $query)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit(search)
                    .disabled(searchTask != nil)
                Button("Search Kiwix", systemImage: "magnifyingglass", action: search)
                    .disabled(searchTask != nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if searchTask != nil {
                    ProgressView("Searching the publisher catalog")
                    Button("Cancel search", role: .cancel) { searchTask?.cancel() }
                }
                if let error { Text(error).foregroundStyle(.secondary) }
            } footer: {
                Text("Search sends the words you enter to the online Kiwix catalog. Use Library to search your installed books offline.")
            }
            if let books {
                Section {
                    if books.isEmpty { Text("No matching downloadable books.").foregroundStyle(.secondary) }
                    ForEach(books) { book in
                        NavigationLink {
                            KiwixBookView(book: book, library: library, onImport: onImport)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.title).font(.headline)
                                Text("About \(book.estimatedBytes.formatted(.byteCount(style: .file)))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if !book.language.isEmpty {
                                    Text(book.language).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Publisher results")
                } footer: {
                    Text("Search shows up to \(KiwixPublisherClient.resultLimit) books. Narrow the topic to find a specific edition.")
                }
            }
        }
        .navigationTitle("Find publisher books")
        .onChange(of: query) {
            books = nil
            error = nil
        }
        .onDisappear { searchTask?.cancel() }
    }

    private func search() {
        guard searchTask == nil else { return }
        let requested = query
        books = nil
        error = nil
        searchTask = Task { @MainActor in
            defer { searchTask = nil }
            do {
                let results = try await KiwixPublisherClient.search(requested)
                try Task.checkCancellation()
                books = results
            } catch where Task.isCancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct KiwixBookView: View {
    let book: KiwixCatalog.Book
    let library: InstalledLibrary
    let onImport: () async -> Void
    @State private var metadata: KiwixMetalink?
    @State private var reviewTask: Task<Void, Never>?
    @State private var importTask: Task<Void, Never>?
    @State private var importAttempt: UUID?
    @State private var choosing = false
    @State private var progress = 0.0
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text(book.title).font(.headline)
                if !book.summary.isEmpty { Text(book.summary) }
                if !book.creator.isEmpty { LabeledContent("Creator", value: book.creator) }
                if !book.language.isEmpty { LabeledContent("Language codes", value: book.language) }
                if !book.updated.isEmpty { LabeledContent("Catalog update", value: String(book.updated.prefix(10))) }
                if let reader = book.readerURL { Link("Read online at Kiwix", destination: reader) }
            }
            Section {
                Link("Open archive download at Kiwix", destination: book.archiveURL)
                    .disabled(importTask != nil)
                if let metadata {
                    LabeledContent("Archive file", value: metadata.filename)
                    LabeledContent("Publisher size", value: metadata.byteCount.formatted(.byteCount(style: .file)))
                    LabeledContent {
                        Text(metadata.sha256).font(.caption.monospaced()).textSelection(.enabled)
                    } label: {
                        Text("Publisher SHA-256")
                    }
                    Button("Verify and import downloaded ZIM", systemImage: "folder") { choosing = true }
                        .disabled(importTask != nil || message != nil)
                } else if reviewTask != nil {
                    ProgressView("Checking publisher file")
                    Button("Cancel check", role: .cancel) { reviewTask?.cancel() }
                } else {
                    Button("Check publisher file", systemImage: "checkmark.shield", action: review)
                }
                if importTask != nil {
                    if progress < 1 {
                        ProgressView("Copying archive", value: progress)
                    } else {
                        ProgressView("Verifying archive")
                    }
                    Button("Cancel import", role: .cancel) { importTask?.cancel() }
                }
                if let message { Label(message, systemImage: "checkmark.circle") }
                if let error { Text(error).foregroundStyle(.secondary) }
            } header: {
                Text("Offline archive")
            } footer: {
                Text("Check the publisher’s terms before reusing any content. Save the ZIM to Files, then select it here to check the publisher’s size and SHA-256 before importing.")
            }
        }
        .navigationTitle("Publisher book")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [UTType(filenameExtension: "zim") ?? .data],
                      onCompletion: importFile)
        .onDisappear {
            reviewTask?.cancel()
            importTask?.cancel()
        }
    }

    private func review() {
        guard reviewTask == nil else { return }
        error = nil
        reviewTask = Task { @MainActor in
            defer { reviewTask = nil }
            do {
                let checkedFile = try await KiwixPublisherClient.metadata(for: book)
                try Task.checkCancellation()
                metadata = checkedFile
            } catch where Task.isCancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard importTask == nil, let metadata else { return }
        let stem = book.archiveURL.deletingPathExtension().lastPathComponent
        let version = String(stem.suffix(7))
        let edition = version.range(of: #"^[0-9]{4}-[0-9]{2}$"#, options: .regularExpression) == nil
            ? "publisher-edition" : version
        let attribution = book.creator.isEmpty ? "Archive distributed by Kiwix"
            : "\(book.creator) · archive distributed by Kiwix"
        let pack = PublishedPack(id: "kiwix-\(metadata.sha256)", title: book.title, version: edition,
                                 source: book.archiveURL, sha256: metadata.sha256,
                                 sizeEstimate: metadata.byteCount, attribution: attribution)
        let attempt = UUID()
        importAttempt = attempt
        progress = 0
        error = nil
        importTask = Task { @MainActor in
            defer {
                importAttempt = nil
                importTask = nil
            }
            do {
                _ = try await library.importPublishedPack(pack, from: result.get()) { fraction in
                    Task { @MainActor in
                        if importAttempt == attempt { progress = max(progress, fraction) }
                    }
                }
                await onImport()
                message = "Verified and added to Library."
            } catch where Task.isCancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
