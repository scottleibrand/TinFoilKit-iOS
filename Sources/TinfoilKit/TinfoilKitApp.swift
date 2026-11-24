import SwiftUI
import UniformTypeIdentifiers
import ZIMArchive

@main
struct TinfoilKitApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var appDelegate
    @StateObject private var packs = PackDownloads.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                LibraryView(library: .standard, packs: packs)
                    .tabItem { Label("Library", systemImage: "books.vertical") }
                OfflineMapView()
                    .tabItem { Label("Map", systemImage: "map") }
            }
        }
    }
}

private struct LibraryView: View {
    let library: InstalledLibrary
    @ObservedObject var packs: PackDownloads
    @State private var archives: [InstalledArchive] = []
    @State private var choosingArchive = false
    @State private var importing = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var results: [SummarySource] = []
    @State private var summary: SummaryRequest?
    @State private var sharedArchive: SharedArchive?
    @State private var searchable: [UUID] = []
    @State private var indexing: IndexStatus?
    @State private var indexErrors: [UUID: String] = [:]
    @State private var indexAttempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if archives.isEmpty {
                    ContentUnavailableView {
                        Label("No archives installed", systemImage: "books.vertical")
                    } description: {
                        Text("Import a ZIM archive to read it offline.")
                    } actions: {
                        Button("Import from Files") { choosingArchive = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(importing)
                    }
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    List {
                        ForEach(archives) { archive in
                            NavigationLink {
                                ArchiveReaderView(library: library, archive: archive)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(archive.title)
                                    Text(archive.byteCount.formatted(.byteCount(style: .file)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let error = indexErrors[archive.id] {
                                        Text(error).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contextMenu {
                                if archive.pack != nil {
                                    Button("Share archive", systemImage: "square.and.arrow.up") {
                                        Task {
                                            let file = await library.fileURL(for: archive.id)
                                            sharedArchive = SharedArchive(file: file, title: archive.title)
                                        }
                                    }
                                }
                            }
                        }
                        if archives.contains(where: { indexErrors[$0.id] != nil && $0.byteCount <= ArticleIndex.maximumArchiveSize }) {
                            Button("Retry search indexing") { indexAttempt += 1 }
                        }
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        if ArticleSummaryView.isAvailable {
                            Button("Summarize matching articles", systemImage: "text.justify.leading") {
                                summary = SummaryRequest(question: query, sources: Array(results.prefix(5)))
                            }
                        }
                        ForEach(results) { result in
                            NavigationLink {
                                ArchiveReaderView(library: library, archive: result.archive, articlePath: result.match.path)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.match.title)
                                    Text(result.match.excerpt).font(.subheadline).lineLimit(3)
                                    Text(result.archive.title).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search installed articles")
            .toolbar {
                NavigationLink {
                    PacksView(downloads: packs)
                } label: {
                    Label("Content packs", systemImage: "arrow.down.circle")
                }
                NavigationLink {
                    DesktopKitView()
                } label: {
                    Label("Desktop kit", systemImage: "desktopcomputer")
                }
                if !archives.isEmpty {
                    Button("Import archive", systemImage: "plus") { choosingArchive = true }
                        .disabled(importing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if importing {
                    ProgressView("Importing archive")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                } else if let indexing {
                    ProgressView(value: indexing.progress) { Text("Indexing \(indexing.title)") }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
            }
            .fileImporter(
                isPresented: $choosingArchive,
                allowedContentTypes: [UTType(filenameExtension: "zim") ?? .data]
            ) { result in
                Task { await importArchive(result) }
            }
            .alert("Library error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await packs.restore() }
            .task(id: packs.installedRevision) { await refresh() }
            .task(id: IndexRun(ids: archives.map(\.id), attempt: indexAttempt)) {
                await buildIndexes()
            }
            .task(id: SearchRun(query: query, ids: searchable)) {
                await search()
            }
            .sheet(item: $summary) { request in
                ArticleSummaryView(library: library, question: request.question, sources: request.sources)
            }
            .sheet(item: $sharedArchive) { archive in
                VStack(alignment: .leading, spacing: 12) {
                    Text(archive.title).font(.headline)
                    ShareLink(item: archive.file, preview: SharePreview(archive.title))
                }
                .padding()
                .presentationDetents([.height(140)])
            }
        }
    }

    private func refresh() async {
        do {
            archives = try await library.archives()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importArchive(_ result: Result<URL, Error>) async {
        importing = true
        defer { importing = false }
        do {
            try await library.importArchive(from: result.get())
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buildIndexes() async {
        for archive in archives {
            guard !Task.isCancelled else { return }
            if archive.byteCount > ArticleIndex.maximumArchiveSize {
                indexErrors[archive.id] = "Search is available for archives up to 1 GB."
                continue
            }
            let url = await library.fileURL(for: archive.id)
            let index = ArticleIndex(archiveURL: url)
            do {
                if !index.isReady {
                    indexing = IndexStatus(id: archive.id, title: archive.title, progress: 0)
                    indexErrors[archive.id] = nil
                    let worker = Task.detached(priority: .utility) {
                        try index.build(archiveURL: url) { value in
                            Task { @MainActor in
                                if indexing?.id == archive.id {
                                    indexing?.progress = value
                                }
                            }
                        }
                    }
                    try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    if indexing?.id == archive.id { indexing = nil }
                }
                if !searchable.contains(archive.id) { searchable.append(archive.id) }
            } catch is CancellationError {
                if indexing?.id == archive.id { indexing = nil }
                return
            } catch {
                indexing = nil
                indexErrors[archive.id] = "Search index unavailable. \(error.localizedDescription)"
            }
        }
    }

    private func search() async {
        let requested = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []
        guard !requested.isEmpty else { return }
        do {
            try await Task.sleep(for: .milliseconds(180))
            let installed = archives.filter { searchable.contains($0.id) }
            var sources: [(InstalledArchive, ArticleIndex)] = []
            for archive in installed {
                let url = await library.fileURL(for: archive.id)
                sources.append((archive, ArticleIndex(archiveURL: url)))
            }
            let matches = try await Task.detached(priority: .userInitiated) {
                try sources.flatMap { archive, index in
                    try index.search(requested).map { SummarySource(archive: archive, match: $0) }
                }.sorted { $0.match.rank < $1.match.rank }
            }.value
            if !Task.isCancelled { results = Array(matches.prefix(50)) }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private struct IndexStatus {
        let id: UUID
        let title: String
        var progress: Double
    }

    private struct IndexRun: Equatable {
        let ids: [UUID]
        let attempt: Int
    }

    private struct SearchRun: Equatable {
        let query: String
        let ids: [UUID]
    }

    private struct SummaryRequest: Identifiable {
        let id = UUID()
        let question: String
        let sources: [SummarySource]
    }

    private struct SharedArchive: Identifiable {
        let id = UUID()
        let file: URL
        let title: String
    }
}
