import Foundation
import SwiftUI
import UIKit
import ZIMArchive

@MainActor
final class PackDownloads: ObservableObject {
    static let shared = PackDownloads()

    typealias CatalogEntry = PackCatalog.Entry

    static let catalog = PackCatalog.entries.map(\.pack)
    private static let defaultPacks = PackCatalog.entries.filter(\.isDefault).map(\.pack)
    private static let essentials = PackCatalog.entries.filter {
        $0.section == .essentials && $0.isDefault
    }.map(\.pack)

    static func allowsArchiveSharing(_ pack: PublishedPack) -> Bool {
        PackCatalog.entries.first { $0.pack == pack }?.allowsArchiveSharing == true
    }

    static func usesPDFDirectory(_ pack: PublishedPack) -> Bool {
        PackCatalog.entries.first { $0.pack.id == pack.id }?.usesPDFDirectory == true
    }

    @Published private(set) var statuses: [String: Status] = [:]
    @Published private(set) var restoring = true
    @Published private(set) var installedRevision = 0
    @Published private(set) var downloadAllError: String?

    var downloadAllSizeEstimate: Int64 {
        sizeEstimate(for: Self.defaultPacks)
    }

    var essentialsSizeEstimate: Int64 { sizeEstimate(for: Self.essentials) }

    private let library = InstalledLibrary.standard
    private let staging = URL.applicationSupportDirectory.appendingPathComponent("PackDownloads", isDirectory: true)
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var restoringStarted = false
    private var backgroundCompletion: (() -> Void)?
    private lazy var transfer = PackTransfer(directory: staging) { [weak self] event in
        Task { @MainActor in self?.handle(event) }
    }

    enum Status {
        case downloading(Double?)
        case pausing
        case paused
        case verifying
        case installed
        case failed(String)
    }

    func restore() async {
        guard !restoringStarted else { return }
        restoringStarted = true
        defer { restoring = false }
        let sessionTasks = await transfer.session.allTasks
        let installed = (try? await library.archives()) ?? []
        for pack in Self.catalog {
            let key = pack.editionKey
            if case .verifying = statuses[key] { continue }
            let repair = repairTarget(key)
            let update = updateTarget(key)
            if repair == nil, let current = installed.first(where: { $0.pack == pack }),
               update == nil || current.replacesArchiveID == update {
                if update != nil { try? FileManager.default.removeItem(at: updateURL(key)) }
                try? FileManager.default.removeItem(at: transfer.downloadURL(key))
                try? FileManager.default.removeItem(at: transfer.resumeURL(key))
                statuses[key] = .installed
            } else if let task = sessionTasks.first(where: { $0.taskDescription == key }) as? URLSessionDownloadTask {
                tasks[key] = task
                statuses[key] = .downloading(nil)
            } else if FileManager.default.fileExists(atPath: transfer.downloadURL(key).path) {
                install(pack)
            } else if FileManager.default.fileExists(atPath: transfer.resumeURL(key).path) {
                statuses[key] = .paused
            } else if repair != nil || update != nil {
                statuses[key] = .failed("The download was interrupted. Retry to continue.")
            }
        }
    }

    func start(_ pack: PublishedPack) {
        guard !restoring, canStart(pack) else { return }
        downloadAllError = nil
        do {
            try enqueue([pack])
        } catch {
            statuses[pack.editionKey] = .failed(error.localizedDescription)
        }
    }

    func startAll() {
        startBatch(Self.defaultPacks)
    }

    func startEssentials() {
        startBatch(Self.essentials)
    }

    private func sizeEstimate(for packs: [PublishedPack]) -> Int64 {
        packs.filter(canStart).reduce(0) { $0 + $1.sizeEstimate }
    }

    private func startBatch(_ packs: [PublishedPack]) {
        guard !restoring else { return }
        let eligible = packs.filter(canStart)
        guard !eligible.isEmpty else { return }
        downloadAllError = nil
        do {
            try enqueue(eligible)
        } catch {
            downloadAllError = error.localizedDescription
        }
    }

    func archiveRemoved(_ archive: InstalledArchive) {
        guard let pack = archive.pack else { return }
        let key = pack.editionKey
        if repairTarget(key) == archive.id {
            try? FileManager.default.removeItem(at: repairURL(key))
            try? FileManager.default.removeItem(at: transfer.resumeURL(key))
            try? FileManager.default.removeItem(at: transfer.downloadURL(key))
            statuses[key] = nil
        } else if case .installed = statuses[key] {
            statuses[key] = nil
        }
        for replacement in Self.catalog where updateTarget(replacement.editionKey) == archive.id {
            let updateKey = replacement.editionKey
            tasks.removeValue(forKey: updateKey)?.cancel()
            try? FileManager.default.removeItem(at: updateURL(updateKey))
            try? FileManager.default.removeItem(at: transfer.resumeURL(updateKey))
            try? FileManager.default.removeItem(at: transfer.downloadURL(updateKey))
            statuses[updateKey] = nil
        }
    }

    func availableUpdate(for archive: InstalledArchive) -> PublishedPack? {
        guard !restoring, let previous = archive.pack, !isRepairing(archive) else { return nil }
        if let pending = Self.catalog.first(where: { updateTarget($0.editionKey) == archive.id }) {
            return canStart(pending) ? pending : nil
        }
        return Self.catalog.filter {
            $0.id == previous.id && previous.version < $0.version && updateTarget($0.editionKey) == nil
        }.max { $0.version < $1.version }.flatMap { pack in
            if case .installed = statuses[pack.editionKey] { return pack }
            return canStart(pack) ? pack : nil
        }
    }

    func update(_ archive: InstalledArchive, to replacement: PublishedPack) async throws {
        guard availableUpdate(for: archive) == replacement else { return }
        let key = replacement.editionKey
        if case .installed = statuses[key] {
            statuses[key] = .verifying
            defer { statuses[key] = .installed }
            try await library.installPack(replacement, from: transfer.downloadURL(key), replacing: archive.id)
            installedRevision += 1
            return
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let wasPending = updateTarget(key) != nil
        if !wasPending {
            try Data(archive.id.uuidString.utf8).write(to: updateURL(key), options: .atomic)
        }
        do {
            try enqueue([replacement])
        } catch {
            if !wasPending { try? FileManager.default.removeItem(at: updateURL(key)) }
            throw error
        }
    }

    func isDownloadingUpdate(for archive: InstalledArchive) -> Bool {
        Self.catalog.contains { pack in
            let key = pack.editionKey
            guard updateTarget(key) == archive.id else { return false }
            switch statuses[key] {
            case .pausing, .downloading, .verifying: return true
            default: return false
            }
        }
    }

    func canRepair(_ archive: InstalledArchive) -> Bool {
        guard !restoring, let pack = archive.pack, Self.catalog.contains(pack), !isDownloadingUpdate(for: archive),
              tasks[pack.editionKey] == nil else { return false }
        if case .installed = statuses[pack.editionKey] { return true }
        return false
    }

    func isRepairing(_ archive: InstalledArchive) -> Bool {
        guard let pack = archive.pack, repairTarget(pack.editionKey) == archive.id else { return false }
        switch statuses[pack.editionKey] {
        case .pausing, .downloading, .verifying: return true
        default: return false
        }
    }

    func repair(_ archive: InstalledArchive) throws {
        guard canRepair(archive), let pack = archive.pack else { return }
        let key = pack.editionKey
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(archive.id.uuidString.utf8).write(to: repairURL(key), options: .atomic)
        do {
            try enqueue([pack])
        } catch {
            try? FileManager.default.removeItem(at: repairURL(key))
            throw error
        }
    }

    private func repairURL(_ key: String) -> URL {
        staging.appendingPathComponent(key).appendingPathExtension("repair")
    }

    private func repairTarget(_ key: String) -> UUID? {
        (try? String(contentsOf: repairURL(key), encoding: .utf8)).flatMap(UUID.init(uuidString:))
    }

    private func updateURL(_ key: String) -> URL {
        staging.appendingPathComponent(key).appendingPathExtension("update")
    }

    private func updateTarget(_ key: String) -> UUID? {
        (try? String(contentsOf: updateURL(key), encoding: .utf8)).flatMap(UUID.init(uuidString:))
    }

    private func canStart(_ pack: PublishedPack) -> Bool {
        let key = pack.editionKey
        guard tasks[key] == nil else { return false }
        switch statuses[key] {
        case nil, .paused, .failed: return true
        case .downloading, .pausing, .verifying, .installed: return false
        }
    }

    private func enqueue(_ packs: [PublishedPack]) throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var directory = staging
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let downloadAndIndexBytes = packs.reduce(Int64.zero) { $0 + capacityEstimate(for: $1) }
        let reservedBytes = Self.catalog.reduce(Int64.zero) { total, pack in
            let key = pack.editionKey
            switch statuses[key] {
            case .downloading:
                let received = max(0, tasks[key]?.countOfBytesReceived ?? 0)
                return total + capacityEstimate(for: pack) - min(received, pack.sizeEstimate)
            case .verifying:
                return total + capacityEstimate(for: pack) - pack.sizeEstimate
            default:
                return total
            }
        }
        let required = downloadAndIndexBytes + reservedBytes + 64 * 1024 * 1024
        if let bytes = available.volumeAvailableCapacityForImportantUsage, bytes < required {
            throw InsufficientStorage(shortfall: required - bytes)
        }
        for pack in packs {
            let key = pack.editionKey
            let task: URLSessionDownloadTask
            if let resume = try? Data(contentsOf: transfer.resumeURL(key)) {
                task = transfer.session.downloadTask(withResumeData: resume)
            } else {
                task = transfer.session.downloadTask(with: pack.source)
            }
            task.taskDescription = key
            tasks[key] = task
            statuses[key] = .downloading(nil)
            task.resume()
        }
    }

    private func capacityEstimate(for pack: PublishedPack) -> Int64 {
        // Downloads move into the library. Only a new edition needs room for another index.
        repairTarget(pack.editionKey) == nil ? pack.sizeEstimate * 2 : pack.sizeEstimate
    }

    private struct InsufficientStorage: LocalizedError {
        let shortfall: Int64

        var errorDescription: String? {
            "Free up at least \(shortfall.formatted(.byteCount(style: .file))) to download and index the selected content."
        }
    }

    func pause(_ pack: PublishedPack) {
        let key = pack.editionKey
        guard let task = tasks.removeValue(forKey: key) else { return }
        statuses[key] = .pausing
        task.cancel { [weak self] resumeData in
            Task { @MainActor in
                guard let self else { return }
                if let resumeData { try? self.transfer.saveResume(resumeData, key: key) }
                if case .pausing = self.statuses[key] { self.statuses[key] = .paused }
            }
        }
    }

    func resumeBackgroundSession(completion: @escaping () -> Void) {
        backgroundCompletion = completion
        _ = transfer.session
    }

    private func handle(_ event: PackTransfer.Event) {
        switch event {
        case let .progress(key, fraction):
            if case .downloading = statuses[key] { statuses[key] = .downloading(fraction) }
        case let .downloaded(key):
            tasks[key] = nil
            if let pack = Self.catalog.first(where: { $0.editionKey == key }) { install(pack) }
        case let .failed(key, message):
            tasks[key] = nil
            if case .pausing = statuses[key] { return }
            statuses[key] = .failed(message)
        case .finishedEvents:
            backgroundCompletion?()
            backgroundCompletion = nil
        }
    }

    private func install(_ pack: PublishedPack) {
        let key = pack.editionKey
        if case .verifying = statuses[key] { return }
        statuses[key] = .verifying
        let file = transfer.downloadURL(key)
        Task {
            do {
                if let archiveID = repairTarget(key) {
                    try await library.repairPack(pack, archiveID: archiveID, from: file, movingSource: true)
                    try FileManager.default.removeItem(at: repairURL(key))
                } else {
                    try await library.installPack(pack, from: file, replacing: updateTarget(key), movingSource: true)
                    try? FileManager.default.removeItem(at: updateURL(key))
                }
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: transfer.resumeURL(key))
                statuses[key] = .installed
                installedRevision += 1
            } catch {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: transfer.resumeURL(key))
                statuses[key] = .failed(error.localizedDescription)
            }
        }
    }
}

private final class PackTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "org.tinfoilkit.ios.publisher-packs"

    enum Event: Sendable {
        case progress(String, Double?)
        case downloaded(String)
        case failed(String, String)
        case finishedEvents
    }

    private let directory: URL
    private let post: @Sendable (Event) -> Void
    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(directory: URL, post: @escaping @Sendable (Event) -> Void) {
        self.directory = directory
        self.post = post
    }

    func downloadURL(_ key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("zim")
    }

    func resumeURL(_ key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("resume")
    }

    func saveResume(_ data: Data, key: String) throws {
        try data.write(to: resumeURL(key), options: .atomic)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard let key = downloadTask.taskDescription else { return }
        guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            post(.failed(key, "The publisher did not return the archive."))
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = downloadURL(key)
            if !FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.moveItem(at: location, to: file)
            }
            post(.downloaded(key))
        } catch {
            post(.failed(key, error.localizedDescription))
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let key = downloadTask.taskDescription else { return }
        let fraction = totalBytesExpectedToWrite > 0
            ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil
        post(.progress(key, fraction))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription, let error = error as NSError? else { return }
        if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? saveResume(data, key: key)
        }
        guard error.code != NSURLErrorCancelled || error.domain != NSURLErrorDomain else { return }
        post(.failed(key, error.localizedDescription))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        post(.finishedEvents)
    }
}

final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == PackTransfer.identifier else { completionHandler(); return }
        PackDownloads.shared.resumeBackgroundSession(completion: completionHandler)
    }
}
