import SwiftUI
import UniformTypeIdentifiers
import ZIMArchive

struct KiwixDiscoveryView: View {
    @ObservedObject var downloads: PackDownloads
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
                            KiwixBookView(book: book, downloads: downloads, library: library, onImport: onImport)
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
    @ObservedObject var downloads: PackDownloads
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
                if let metadata, let candidate = KiwixDownloadApproval.pack(for: book, metadata: metadata) {
                    let pack = downloads.publisherEdition(for: candidate)
                    LabeledContent("Archive file", value: metadata.filename)
                    LabeledContent("Publisher size", value: metadata.byteCount.formatted(.byteCount(style: .file)))
                    LabeledContent {
                        Text(metadata.sha256).font(.caption.monospaced()).textSelection(.enabled)
                    } label: {
                        Text("Publisher SHA-256")
                    }
                    if message == nil {
                        PackDownloadControls(downloads: downloads, pack: pack)
                            .disabled(importTask != nil || choosing)
                        if canImport(for: pack) {
                            Button("Verify and import downloaded ZIM", systemImage: "folder") { choosing = true }
                                .disabled(importTask != nil)
                        }
                    }
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
                Text("Downloads use Wi-Fi unless you allow cellular data. The app checks the publisher’s exact size and SHA-256 before installation. You can also verify a ZIM from Files. Check the publisher’s terms before reusing content.")
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
                guard KiwixDownloadApproval.pack(for: book, metadata: checkedFile) != nil else {
                    throw KiwixMetalink.ParseError.invalidMetadata
                }
                metadata = checkedFile
            } catch where Task.isCancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func canImport(for pack: PublishedPack) -> Bool {
        switch downloads.status(for: pack) {
        case nil, .failed: return true
        default: return false
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard importTask == nil, let metadata,
              let candidate = KiwixDownloadApproval.pack(for: book, metadata: metadata) else { return }
        let pack = downloads.publisherEdition(for: candidate)
        guard canImport(for: pack) else { return }
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
                let archive = try await library.importPublishedPack(pack, from: result.get()) { fraction in
                    Task { @MainActor in
                        if importAttempt == attempt { progress = max(progress, fraction) }
                    }
                }
                downloads.publisherFileImported(archive, as: pack)
                await onImport()
                message = "Verified and added to Library."
            } catch where Task.isCancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
