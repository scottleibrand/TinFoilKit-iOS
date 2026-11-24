import Combine
import Foundation

/// Owns one indexing queue for the app. Views observe progress without owning the work.
@MainActor
public final class LibraryIndexing: ObservableObject {
    public struct Progress {
        public let id: UUID
        public let title: String
        public fileprivate(set) var fraction: Double
    }

    @Published public private(set) var archives: [InstalledArchive] = []
    @Published public private(set) var damagedArchiveIDs: [UUID] = []
    @Published public private(set) var searchable: Set<UUID> = []
    @Published public private(set) var progress: Progress?
    @Published public private(set) var errors: [UUID: String] = [:]
    @Published public private(set) var refreshError: String?

    public var hasPendingIndexes: Bool {
        archives.contains { !completedIndexes.contains($0.id) && errors[$0.id] == nil && !removing.contains($0.id) }
    }

    private let library: InstalledLibrary
    private var worker: Task<Void, Never>?
    private var activeBuild: Task<Void, Error>?
    private var completedIndexes: Set<UUID> = []
    private var removing: Set<UUID> = []
    private var inventoryRevision = 0
    private var refreshGeneration = 0

    public init(library: InstalledLibrary) {
        self.library = library
    }

    public func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let revision = inventoryRevision
        do {
            let inventory = try await library.inventory()
            var readable: Set<UUID> = []
            for archive in inventory.archives {
                let file = await library.fileURL(for: archive.id)
                if ArticleIndex(archiveURL: file).hasSearchableIndex { readable.insert(archive.id) }
            }
            guard revision == inventoryRevision, generation == refreshGeneration else { return }
            archives = inventory.archives
            damagedArchiveIDs = inventory.damaged
            let ids = Set(archives.map(\.id))
            searchable.formIntersection(ids)
            searchable.formUnion(readable)
            completedIndexes.formIntersection(ids)
            errors = errors.filter { ids.contains($0.key) }
            refreshError = nil
            startIfNeeded()
        } catch {
            if revision == inventoryRevision, generation == refreshGeneration {
                refreshError = error.localizedDescription
            }
        }
    }

    public func removeArchive(_ id: UUID) async throws {
        guard removing.insert(id).inserted else { return }
        defer {
            removing.remove(id)
            startIfNeeded()
        }
        if progress?.id == id, let activeBuild {
            activeBuild.cancel()
            _ = await activeBuild.result
        }
        try await library.removeArchive(id)
        inventoryRevision += 1
        archives.removeAll { $0.id == id }
        searchable.remove(id)
        completedIndexes.remove(id)
        errors[id] = nil
        await refresh()
    }

    public func retryFailedIndexes() {
        for archive in archives {
            errors[archive.id] = nil
        }
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { await drainQueue() }
    }

    private func drainQueue() async {
        defer {
            progress = nil
            worker = nil
        }
        for archive in archives where completedIndexes.contains(archive.id) {
            await finishUpdate(archive)
        }
        // Finish smaller packs first so they are searchable while larger editions keep indexing.
        while let archive = archives.filter({
            !completedIndexes.contains($0.id) && errors[$0.id] == nil && !removing.contains($0.id)
        }).min(by: { $0.byteCount < $1.byteCount }) {
            let url = await library.fileURL(for: archive.id)
            guard !removing.contains(archive.id), archives.contains(where: { $0.id == archive.id }) else { continue }
            let index = ArticleIndex(archiveURL: url)
            if !index.isReady {
                progress = Progress(id: archive.id, title: archive.title, fraction: 0)
                let build = Task.detached(priority: .utility) { [weak self] in
                    try index.build(archiveURL: url) { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, self.progress?.id == archive.id else { return }
                            if !self.searchable.contains(archive.id), index.hasSearchableIndex {
                                self.searchable.insert(archive.id)
                            }
                            let latest = max(self.progress?.fraction ?? 0, fraction)
                            self.progress?.fraction = latest
                        }
                    }
                }
                activeBuild = build
                let result = await build.result
                activeBuild = nil
                progress = nil
                guard !removing.contains(archive.id), archives.contains(where: { $0.id == archive.id }) else { continue }
                if case let .failure(error) = result {
                    if !(error is CancellationError) {
                        errors[archive.id] = "Search index unavailable. \(error.localizedDescription)"
                    }
                    continue
                }
            }
            searchable.insert(archive.id)
            completedIndexes.insert(archive.id)
            await finishUpdate(archive)
        }
    }

    private func finishUpdate(_ archive: InstalledArchive) async {
        guard let previousID = archive.replacesArchiveID,
              archives.contains(where: { $0.id == previousID }),
              !removing.contains(previousID), !removing.contains(archive.id) else { return }
        do {
            guard let removedID = try await library.finishUpdate(archive) else { return }
            inventoryRevision += 1
            archives.removeAll { $0.id == removedID }
            searchable.remove(removedID)
            completedIndexes.remove(removedID)
            errors[removedID] = nil
            errors[archive.id] = nil
        } catch {
            errors[archive.id] = "The earlier edition is still installed. \(error.localizedDescription)"
        }
    }
}
