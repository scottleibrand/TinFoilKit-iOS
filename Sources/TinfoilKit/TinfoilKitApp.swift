import Combine
import SwiftUI
import UniformTypeIdentifiers
import ZIMArchive

@main
struct TinfoilKitApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var wsdotClosures = WSDOTClosureStore()
    @StateObject private var packs = PackDownloads.shared
    @StateObject private var indexing = LibraryIndexing(library: .standard)
    @StateObject private var household = HouseholdStore()
    @StateObject private var nearby = NearbyLifecycle()
    @StateObject private var readingShelf = ReadingShelf()
    @StateObject private var nwsAlerts = NWSAlertStore()
    @AppStorage("hasSeenOfflineStarterGuide") private var hasSeenOfflineStarterGuide = false
    @State private var showingOfflineStarterGuide = false
    @State private var selectedTab: Tab = .library
    @State private var pendingMapRequest: MapOpenRequest?

    private enum Tab: Hashable {
        case library, map, ask, household, updates
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                LibraryView(library: .standard, packs: packs, indexing: indexing, household: household)
                    .tabItem { Label("Library", systemImage: "books.vertical") }
                    .tag(Tab.library)
                OfflineMapView(household: household, pendingMapRequest: $pendingMapRequest)
                    .tabItem { Label("Map", systemImage: "map") }
                    .tag(Tab.map)
                AskLibraryView(library: .standard, indexing: indexing, household: household) { request in
                    pendingMapRequest = request
                    selectedTab = .map
                }
                    .tabItem { Label("Ask", systemImage: "questionmark.bubble") }
                    .tag(Tab.ask)
                HouseholdView(household: household)
                    .tabItem { Label("Household", systemImage: "house") }
                    .tag(Tab.household)
                NWSUpdatesView(store: nwsAlerts, roads: wsdotClosures)
                    .tabItem { Label("Updates", systemImage: "exclamationmark.triangle") }
                    .tag(Tab.updates)
            }
            .task { await packs.restore() }
            .task(id: packs.installedRevision) { await indexing.refresh() }
            .task {
                if Bundle.main.object(forInfoDictionaryKey: "TFKLightweightProfile") as? Bool == true,
                   !hasSeenOfflineStarterGuide {
                    showingOfflineStarterGuide = true
                }
            }
            .sheet(isPresented: $showingOfflineStarterGuide, onDismiss: {
                hasSeenOfflineStarterGuide = true
            }) {
                NavigationStack {
                    DisasterStarterView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingOfflineStarterGuide = false }
                            }
                        }
                }
            }
            .onChange(of: indexing.archives) { previous, current in
                let installed = Set(current.map(\.id))
                for archive in previous where !installed.contains(archive.id) {
                    packs.archiveRemoved(archive)
                }
            }
            .onChange(of: scenePhase, initial: true) {
                nearby.updatePhase(scenePhase)
                nwsAlerts.setForeground(scenePhase == .active)
                wsdotClosures.setForeground(scenePhase == .active)
            }
            .environmentObject(nearby)
            .environmentObject(nearby.discovery)
            .environmentObject(wsdotClosures)
            .environmentObject(nearby.notifications)
            .environmentObject(readingShelf)
        }
    }
}

private struct LibraryView: View {
    let library: InstalledLibrary
    @ObservedObject var packs: PackDownloads
    @ObservedObject var indexing: LibraryIndexing
    @ObservedObject var household: HouseholdStore
    @EnvironmentObject private var readingShelf: ReadingShelf
    private var archives: [InstalledArchive] { indexing.archives }
    private var hasLibraryItems: Bool {
        !archives.isEmpty || !indexing.damagedArchiveIDs.isEmpty ||
            !readingShelf.bookmarks.isEmpty || !readingShelf.recent.isEmpty
    }
    @State private var choosingArchive = false
    @State private var importTask: Task<Void, Never>?
    @State private var importProgress = 0.0
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var results: [SummarySource] = []
    @State private var resultsQuery = ""
    @State private var unavailableSearchArchives = 0
    @State private var summary: SummaryRequest?
    @State private var sharedArchive: SharedArchive?
    @State private var pendingRemoval: ArchiveRemoval?
    @State private var pendingUpdate: PackUpdate?
    @State private var verifyingID: UUID?
    @State private var verificationMessage: String?

    var body: some View {
        NavigationStack {
            libraryWithDialogs
            .task(id: searchQuery) {
                await search(searchQuery)
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

    private var libraryWithDialogs: some View {
        libraryWithControls
        .alert("Library error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: indexing.refreshError, initial: true) {
            if let error = indexing.refreshError { errorMessage = error }
        }
        .confirmationDialog(
            "Remove offline archive?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { archive in
            Button("Remove from this device", role: .destructive) {
                Task { await remove(archive.id) }
            }
        } message: { archive in
            Text(archive.message)
        }
        .confirmationDialog(
            "Update offline archive?",
            isPresented: Binding(
                get: { pendingUpdate != nil },
                set: { if !$0 { pendingUpdate = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUpdate
        ) { update in
            Button("Update to \(update.replacement.version)") {
                Task {
                    do { try await packs.update(update.archive, to: update.replacement) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        } message: { update in
            Text("The current edition stays available until the new edition has been verified and indexed.")
        }
        .alert("Checksum verified", isPresented: Binding(
            get: { verificationMessage != nil },
            set: { if !$0 { verificationMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(verificationMessage ?? "") }
    }

    private var libraryWithControls: some View {
        libraryContent
        .navigationTitle("Library")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search installed articles")
        .toolbar {
            NavigationLink {
                PacksView(downloads: packs, library: library) { await indexing.refresh() }
            } label: {
                Label("Content packs", systemImage: "arrow.down.circle")
            }
            NavigationLink {
                DesktopKitView()
            } label: {
                Label("Desktop kit", systemImage: "desktopcomputer")
            }
            NavigationLink {
                OfflineReadinessView(indexing: indexing, household: household)
            } label: {
                Label("Offline readiness", systemImage: "checkmark.circle")
            }
            if hasLibraryItems {
                Button("Import archive", systemImage: "plus") { choosingArchive = true }
                    .disabled(importTask != nil)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let importTask {
                HStack {
                    ProgressView(value: importProgress) { Text("Importing archive") }
                    Button("Cancel") { importTask.cancel() }
                }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            } else if let progress = indexing.progress {
                ProgressView(value: progress.fraction) { Text("Indexing \(progress.title)") }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .fileImporter(
            isPresented: $choosingArchive,
            // File providers can advertise ZIM archives as generic data.
            // The library validates the extension and archive format on import.
            allowedContentTypes: [.data]
        ) { result in
            beginImport(result)
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if !hasLibraryItems {
            ContentUnavailableView {
                Label("No archives installed", systemImage: "books.vertical")
            } description: {
                Text("Import a ZIM archive to read it offline.")
            } actions: {
                NavigationLink("Offline starter guide") { DisasterStarterView() }
                    .buttonStyle(.borderedProminent)
                NavigationLink("Find nearby") { NearbyView() }
                    .buttonStyle(.bordered)
                Button("Import from Files") { choosingArchive = true }
                    .buttonStyle(.bordered)
                    .disabled(importTask != nil)
            }
        } else if searchQuery.isEmpty {
            archiveList
        } else if resultsQuery != searchQuery {
            ProgressView("Searching library")
        } else if results.isEmpty {
            if unavailableSearchArchives > 0 {
                ContentUnavailableView("No matches found", systemImage: "magnifyingglass",
                                       description: Text("Some archives could not be fully searched."))
            } else if indexing.hasPendingIndexes {
                ContentUnavailableView("No matches yet", systemImage: "magnifyingglass",
                                       description: Text("Search updates as more articles are indexed."))
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            searchResults
        }
    }

    private var searchResults: some View {
        let passages = results.filter { !$0.match.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return List {
            if unavailableSearchArchives > 0 {
                Text("Some archives could not be fully searched.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if ArticleSummaryView.isAvailable, !passages.isEmpty {
                Button("Summarize matching articles", systemImage: "text.justify.leading") {
                    summary = SummaryRequest(question: query, sources: Array(passages.prefix(5)))
                }
            }
            ForEach(results) { result in
                NavigationLink {
                    ArchiveReaderView(library: library, archive: result.archive, articlePath: result.match.path)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.match.title)
                        if !result.match.excerpt.isEmpty {
                            Text(result.match.excerpt).font(.subheadline).lineLimit(3)
                        }
                        Text(result.archive.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var archiveList: some View {
        List {
            NavigationLink {
                ReadingShelfView(library: library, indexing: indexing)
            } label: {
                Label("Reading list", systemImage: "bookmark")
            }
            NavigationLink {
                NearbyView()
            } label: {
                Label("Find nearby", systemImage: "dot.radiowaves.left.and.right")
            }
            NavigationLink("Offline starter guide") { DisasterStarterView() }
            if !indexing.damagedArchiveIDs.isEmpty {
                Section("Damaged archives") {
                    ForEach(indexing.damagedArchiveIDs, id: \.self) { id in
                        Button("Remove damaged archive \(id.uuidString.prefix(8))", systemImage: "exclamationmark.triangle") {
                            pendingRemoval = ArchiveRemoval(
                                id: id, message: "This removes the damaged archive. You can download or import it again."
                            )
                        }
                    }
                }
            }
            ForEach(archives) { archive in
                NavigationLink {
                    ArchiveReaderView(library: library, archive: archive)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(archive.title)
                        Text(archive.byteCount.formatted(.byteCount(style: .file)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let pack = archive.pack {
                            Text(pack.version).font(.caption).foregroundStyle(.secondary)
                        }
                        if verifyingID == archive.id {
                            ProgressView("Verifying checksum").controlSize(.small)
                        }
                        if packs.isRepairing(archive) {
                            ProgressView("Repairing archive").controlSize(.small)
                        }
                        if packs.isDownloadingUpdate(for: archive) {
                            ProgressView("Downloading update").controlSize(.small)
                        } else if let replacement = replacementBeingIndexed(for: archive),
                                  let version = replacement.pack?.version {
                            Text("Update to \(version) pending")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = indexing.errors[archive.id] {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    if replacementBeingIndexed(for: archive) == nil,
                       !archives.contains(where: { $0.id == archive.replacesArchiveID }),
                       let replacement = packs.availableUpdate(for: archive) {
                        Button("Update to \(replacement.version)", systemImage: "arrow.down.circle") {
                            pendingUpdate = PackUpdate(archive: archive, replacement: replacement)
                        }
                        .disabled(verifyingID == archive.id)
                    }
                    Button("Verify checksum", systemImage: "checkmark.shield") {
                        Task { await verify(archive) }
                    }
                    .disabled(verifyingID != nil || packs.isRepairing(archive))
                    if packs.canRepair(archive) {
                        Button("Repair archive", systemImage: "arrow.clockwise") {
                            do { try packs.repair(archive) }
                            catch { errorMessage = error.localizedDescription }
                        }
                        .disabled(verifyingID == archive.id)
                    }
                    if let pack = archive.pack, PackDownloads.allowsArchiveSharing(pack) {
                        Button("Share archive", systemImage: "square.and.arrow.up") {
                            Task {
                                let file = await library.fileURL(for: archive.id)
                                sharedArchive = SharedArchive(file: file, title: archive.title)
                            }
                        }
                    }
                    Button("Remove archive", systemImage: "trash", role: .destructive) {
                        pendingRemoval = ArchiveRemoval(
                            id: archive.id, message: "\(archive.title) and its search index will be removed."
                        )
                    }
                    .disabled(verifyingID == archive.id || packs.isRepairing(archive)
                              || packs.isDownloadingUpdate(for: archive))
                }
            }
            if !indexing.errors.isEmpty {
                Button("Retry search indexing") { indexing.retryFailedIndexes() }
            }
        }
    }

    private func replacementBeingIndexed(for archive: InstalledArchive) -> InstalledArchive? {
        archives.first { $0.replacesArchiveID == archive.id }
    }

    private struct ArchiveRemoval {
        let id: UUID
        let message: String
    }

    private struct PackUpdate {
        let archive: InstalledArchive
        let replacement: PublishedPack
    }

    private func verify(_ archive: InstalledArchive) async {
        guard verifyingID == nil else { return }
        verifyingID = archive.id
        defer { verifyingID = nil }
        do {
            try await library.verifyArchive(archive)
            verificationMessage = if archive.pack != nil {
                "\(archive.title) matches the publisher’s SHA-256 checksum."
            } else {
                "\(archive.title) matches its embedded ZIM checksum."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ id: UUID) async {
        do {
            try await indexing.removeArchive(id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginImport(_ result: Result<URL, Error>) {
        guard importTask == nil else { return }
        importProgress = 0
        importTask = Task {
            defer { importTask = nil }
            do {
                try await library.importArchive(from: result.get()) { fraction in
                    Task { @MainActor in
                        if importTask != nil { importProgress = max(importProgress, fraction) }
                    }
                }
                await indexing.refresh()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var searchQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func search(_ requested: String) async {
        guard !requested.isEmpty else { return }
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = indexing.$searchRevision.sink { _ in continuation.yield(()) }
        defer {
            observation.cancel()
            continuation.finish()
        }
        do {
            try await Task.sleep(for: .milliseconds(180))
            var titleCache: [UUID: [ZIMArchive.ArticleTitle]] = [:]
            for await _ in updates {
                do {
                    let search = try await searchIndexes(for: requested, titleCache: titleCache)
                    try Task.checkCancellation()
                    titleCache = search.titleCache
                    results = search.matches
                    unavailableSearchArchives = search.unavailableCount
                    resultsQuery = requested
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    if resultsQuery != requested {
                        results = []
                        unavailableSearchArchives = 0
                    }
                    resultsQuery = requested
                    errorMessage = error.localizedDescription
                }
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private func searchIndexes(
        for requested: String, titleCache: [UUID: [ZIMArchive.ArticleTitle]]
    ) async throws -> LibraryArchiveSearch.Output {
        var sources: [(InstalledArchive, URL)] = []
        for archive in archives {
            try Task.checkCancellation()
            let url = await library.fileURL(for: archive.id)
            sources.append((archive, url))
        }
        let inputs = sources
        let worker = Task.detached(priority: .userInitiated) {
            try LibraryArchiveSearch.search(requested, in: inputs, titleCache: titleCache)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
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

enum LibraryResultOrder {
    static func interleave<Result>(_ groups: [[Result]], limit: Int) -> [Result] {
        var ordered: [Result] = []
        for position in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where group.indices.contains(position) {
                if ordered.count == limit { return ordered }
                ordered.append(group[position])
            }
        }
        return ordered
    }
}
