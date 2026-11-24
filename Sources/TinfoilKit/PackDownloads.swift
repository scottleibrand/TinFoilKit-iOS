import Foundation
import SwiftUI
import UIKit
import ZIMArchive

enum PackDownloadNetwork: String, CaseIterable, Sendable {
    case wifiOnly = "org.tinfoilkit.ios.publisher-packs"
    case cellularAllowed = "org.tinfoilkit.ios.publisher-packs.cellular"

    func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: rawValue)
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = self == .cellularAllowed
        return configuration
    }

    var resumeExtension: String { self == .wifiOnly ? "resume" : "cellular-resume" }
}

struct PackDownloadAttempt: Sendable {
    let key: String
    let retryCount: Int
    private static let delays: [TimeInterval] = [2, 5, 15]

    init(key: String, retryCount: Int = 0) {
        self.key = key
        self.retryCount = retryCount
    }

    init?(description: String?) {
        guard let description, !description.isEmpty else { return nil }
        let parts = description.split(separator: "|", omittingEmptySubsequences: false)
        guard let key = parts.first, !key.isEmpty else { return nil }
        if parts.count == 1 {
            self.init(key: String(key))
        } else {
            guard parts.count == 2, let count = Int(parts[1]), (1...Self.delays.count).contains(count) else { return nil }
            self.init(key: String(key), retryCount: count)
        }
    }

    var taskDescription: String { retryCount == 0 ? key : "\(key)|\(retryCount)" }

    func retryDelay(for error: NSError) -> TimeInterval? {
        guard error.domain == NSURLErrorDomain, Self.delays.indices.contains(retryCount) else { return nil }
        switch URLError.Code(rawValue: error.code) {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
             .notConnectedToInternet:
            return Self.delays[retryCount]
        default:
            return nil
        }
    }

    func retryDelay(for response: HTTPURLResponse) -> TimeInterval? {
        guard Self.delays.indices.contains(retryCount),
              [408, 429, 500, 502, 503, 504].contains(response.statusCode) else { return nil }
        guard let retryAfter = response.value(forHTTPHeaderField: "Retry-After") else {
            return Self.delays[retryCount]
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let requested = Int(retryAfter).map(TimeInterval.init)
                ?? formatter.date(from: retryAfter)?.timeIntervalSinceNow,
              requested <= 3600 else { return nil }
        return max(Self.delays[retryCount], requested)
    }
}

@MainActor
final class PackDownloads: ObservableObject {
    static let shared = PackDownloads()

    typealias CatalogEntry = PackCatalog.Entry

    static let catalog = PackCatalog.entries.map(\.pack)
    private static let defaultPacks = PackCatalog.entries.filter(\.isBulkEligible).map(\.pack)
    private static let essentials = PackCatalog.entries.filter {
        $0.section == .essentials && $0.isBulkEligible
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
    private var tasks: [String: (task: URLSessionDownloadTask, network: PackDownloadNetwork)] = [:]
    private var restoringStarted = false
    private var backgroundCompletions: [PackDownloadNetwork: () -> Void] = [:]
    private lazy var transfer = PackTransfer(directory: staging) { [weak self] event in
        Task { @MainActor in self?.handle(event) }
    }

    enum Status {
        case downloading(Double?)
        case retrying
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
        var sessionTasks: [String: (task: URLSessionDownloadTask, network: PackDownloadNetwork)] = [:]
        for network in PackDownloadNetwork.allCases {
            for case let task as URLSessionDownloadTask in await transfer.session(for: network).allTasks {
                guard let attempt = PackDownloadAttempt(description: task.taskDescription),
                      task.state == .running || task.state == .suspended else { continue }
                sessionTasks[attempt.key] = (task, network)
            }
        }
        let installed = (try? await library.archives()) ?? []
        for pack in Self.catalog {
            let key = pack.editionKey
            if tasks[key] != nil { continue }
            if case .verifying = statuses[key] { continue }
            let repair = repairTarget(key)
            let update = updateTarget(key)
            if repair == nil, let current = installed.first(where: { $0.pack == pack }),
               update == nil || current.replacesArchiveID == update {
                if update != nil { try? FileManager.default.removeItem(at: updateURL(key)) }
                try? FileManager.default.removeItem(at: transfer.downloadURL(key))
                transfer.clearResume(key)
                statuses[key] = .installed
            } else if let active = sessionTasks[key] {
                tasks[key] = active
                let retryCount = PackDownloadAttempt(description: active.task.taskDescription)?.retryCount ?? 0
                statuses[key] = retryCount > 0 && active.task.countOfBytesReceived == 0 ? .retrying : .downloading(nil)
            } else if FileManager.default.fileExists(atPath: transfer.downloadURL(key).path) {
                install(pack)
            } else if transfer.hasResume(key) {
                statuses[key] = .paused
            } else if repair != nil || update != nil {
                statuses[key] = .failed("The download was interrupted. Retry to continue.")
            }
        }
    }

    func start(_ pack: PublishedPack, network: PackDownloadNetwork? = nil) {
        guard !restoring, canStart(pack) else { return }
        downloadAllError = nil
        do {
            try enqueue([pack], network: network ?? transfer.resumeNetwork(pack.editionKey))
        } catch {
            statuses[pack.editionKey] = .failed(error.localizedDescription)
        }
    }

    func allowsCellular(for pack: PublishedPack) -> Bool {
        tasks[pack.editionKey]?.network == .cellularAllowed
    }

    func resumesOnCellular(for pack: PublishedPack) -> Bool {
        transfer.resumeNetwork(pack.editionKey) == .cellularAllowed
    }

    func startAll() {
        startBatch(Self.defaultPacks)
    }

    func startEssentials() {
        startBatch(Self.essentials)
    }

    private func sizeEstimate(for packs: [PublishedPack]) -> Int64 {
        packs.filter(canStartOnWiFi).reduce(0) { $0 + $1.sizeEstimate }
    }

    private func startBatch(_ packs: [PublishedPack]) {
        guard !restoring else { return }
        let eligible = packs.filter(canStartOnWiFi)
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
            transfer.clearResume(key)
            try? FileManager.default.removeItem(at: transfer.downloadURL(key))
            statuses[key] = nil
        } else if case .installed = statuses[key] {
            statuses[key] = nil
        }
        for replacement in Self.catalog where updateTarget(replacement.editionKey) == archive.id {
            let updateKey = replacement.editionKey
            tasks.removeValue(forKey: updateKey)?.task.cancel()
            try? FileManager.default.removeItem(at: updateURL(updateKey))
            transfer.clearResume(updateKey)
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
            case .pausing, .downloading, .retrying, .verifying: return true
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
        case .pausing, .downloading, .retrying, .verifying: return true
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
        case .downloading, .retrying, .pausing, .verifying, .installed: return false
        }
    }

    private func canStartOnWiFi(_ pack: PublishedPack) -> Bool {
        canStart(pack) && !resumesOnCellular(for: pack)
    }

    private func enqueue(_ packs: [PublishedPack], network: PackDownloadNetwork = .wifiOnly) throws {
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
            case .downloading, .retrying:
                let received = max(0, tasks[key]?.task.countOfBytesReceived ?? 0)
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
            beginDownload(pack, network: network, attempt: PackDownloadAttempt(key: pack.editionKey))
        }
    }

    private func beginDownload(_ pack: PublishedPack, network: PackDownloadNetwork, attempt: PackDownloadAttempt,
                               delay: TimeInterval? = nil) {
        let session = transfer.session(for: network)
        let resumeURL = transfer.resumeURL(attempt.key, network: network)
        let task: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: resumeURL) {
            task = session.downloadTask(withResumeData: resume)
        } else {
            task = session.downloadTask(with: pack.source)
        }
        task.taskDescription = attempt.taskDescription
        if let delay { task.earliestBeginDate = Date().addingTimeInterval(delay) }
        tasks[attempt.key] = (task, network)
        statuses[attempt.key] = delay == nil ? .downloading(nil) : .retrying
        task.resume()
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
        guard let active = tasks.removeValue(forKey: key) else { return }
        statuses[key] = .pausing
        active.task.cancel { [weak self] resumeData in
            Task { @MainActor in
                guard let self else { return }
                if let resumeData { try? self.transfer.saveResume(resumeData, key: key, network: active.network) }
                if case .pausing = self.statuses[key] { self.statuses[key] = .paused }
            }
        }
    }

    func resumeBackgroundSession(network: PackDownloadNetwork, completion: @escaping () -> Void) {
        backgroundCompletions[network] = completion
        _ = transfer.session(for: network)
    }

    private func handle(_ event: PackTransfer.Event) {
        switch event {
        case let .progress(ticket, fraction):
            guard accepts(ticket) else { return }
            switch statuses[ticket.key] {
            case .downloading, .retrying: statuses[ticket.key] = .downloading(fraction)
            default: break
            }
        case let .downloaded(ticket):
            guard accepts(ticket) else { return }
            let key = ticket.key
            tasks[key] = nil
            if let pack = Self.catalog.first(where: { $0.editionKey == key }) { install(pack) }
        case let .failed(ticket, message, delay):
            let key = ticket.key
            guard accepts(ticket), tasks[key] != nil || restoring else { return }
            tasks[key] = nil
            switch statuses[key] {
            case .pausing, .paused, .verifying, .installed: break
            default:
                if let delay, let pack = Self.catalog.first(where: { $0.editionKey == key }) {
                    beginDownload(pack, network: ticket.network,
                                  attempt: PackDownloadAttempt(key: key, retryCount: ticket.attempt.retryCount + 1),
                                  delay: delay)
                } else {
                    statuses[key] = .failed(message)
                }
            }
        case let .finishedEvents(network):
            backgroundCompletions.removeValue(forKey: network)?()
        }
    }

    private func accepts(_ ticket: PackTransfer.Ticket) -> Bool {
        guard let active = tasks[ticket.key] else { return true }
        return active.network == ticket.network && active.task.taskIdentifier == ticket.taskID
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
                transfer.clearResume(key)
                statuses[key] = .installed
                installedRevision += 1
            } catch {
                try? FileManager.default.removeItem(at: file)
                transfer.clearResume(key)
                statuses[key] = .failed(error.localizedDescription)
            }
        }
    }
}

final class PackTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Ticket: Sendable {
        let attempt: PackDownloadAttempt
        let network: PackDownloadNetwork
        let taskID: Int
        var key: String { attempt.key }

        init?(session: URLSession, task: URLSessionTask) {
            guard let attempt = PackDownloadAttempt(description: task.taskDescription),
                  let identifier = session.configuration.identifier,
                  let network = PackDownloadNetwork(rawValue: identifier) else { return nil }
            self.attempt = attempt
            self.network = network
            taskID = task.taskIdentifier
        }
    }

    enum Event: Sendable {
        case progress(Ticket, Double?)
        case downloaded(Ticket)
        case failed(Ticket, String, retryAfter: TimeInterval?)
        case finishedEvents(PackDownloadNetwork)
    }

    private let directory: URL
    private let post: @Sendable (Event) -> Void
    private lazy var wifi = makeSession(.wifiOnly)
    private lazy var cellular = makeSession(.cellularAllowed)

    func session(for network: PackDownloadNetwork) -> URLSession {
        network == .wifiOnly ? wifi : cellular
    }

    private func makeSession(_ network: PackDownloadNetwork) -> URLSession {
        URLSession(configuration: network.configuration(), delegate: self, delegateQueue: nil)
    }

    init(directory: URL, post: @escaping @Sendable (Event) -> Void) {
        self.directory = directory
        self.post = post
    }

    func downloadURL(_ key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("zim")
    }

    func resumeURL(_ key: String, network: PackDownloadNetwork) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension(network.resumeExtension)
    }

    func hasResume(_ key: String) -> Bool {
        PackDownloadNetwork.allCases.contains { hasResume(key, network: $0) }
    }

    private func hasResume(_ key: String, network: PackDownloadNetwork) -> Bool {
        FileManager.default.fileExists(atPath: resumeURL(key, network: network).path)
    }

    func resumeNetwork(_ key: String) -> PackDownloadNetwork {
        if hasResume(key, network: .cellularAllowed), !hasResume(key, network: .wifiOnly) {
            return .cellularAllowed
        }
        return .wifiOnly
    }

    func clearResume(_ key: String) {
        for network in PackDownloadNetwork.allCases {
            try? FileManager.default.removeItem(at: resumeURL(key, network: network))
        }
    }

    func saveResume(_ data: Data, key: String, network: PackDownloadNetwork) throws {
        try data.write(to: resumeURL(key, network: network), options: .atomic)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard let ticket = Ticket(session: session, task: downloadTask) else { return }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            post(.failed(ticket, "The publisher did not return the archive.", retryAfter: nil))
            return
        }
        guard (200...299).contains(response.statusCode) else {
            post(.failed(ticket, "The publisher did not return the archive (HTTP \(response.statusCode)).",
                         retryAfter: ticket.attempt.retryDelay(for: response)))
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = downloadURL(ticket.key)
            if !FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.moveItem(at: location, to: file)
            }
            post(.downloaded(ticket))
        } catch {
            post(.failed(ticket, error.localizedDescription, retryAfter: nil))
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let ticket = Ticket(session: session, task: downloadTask) else { return }
        let fraction = totalBytesExpectedToWrite > 0
            ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil
        post(.progress(ticket, fraction))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ticket = Ticket(session: session, task: task), let error = error as NSError? else { return }
        guard error.code != NSURLErrorCancelled || error.domain != NSURLErrorDomain else { return }
        if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? saveResume(data, key: ticket.key, network: ticket.network)
        }
        post(.failed(ticket, error.localizedDescription, retryAfter: ticket.attempt.retryDelay(for: error)))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let identifier = session.configuration.identifier, let network = PackDownloadNetwork(rawValue: identifier) {
            post(.finishedEvents(network))
        }
    }
}

final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard let network = PackDownloadNetwork(rawValue: identifier) else { completionHandler(); return }
        PackDownloads.shared.resumeBackgroundSession(network: network, completion: completionHandler)
    }
}
