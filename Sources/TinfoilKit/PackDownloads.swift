import Foundation
import SwiftUI
import UIKit
import ZIMArchive

enum PackDownloadNetwork: String, CaseIterable, Codable, Sendable {
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
    let retriedChecksum: Bool
    let usesMirror: Bool
    private static let delays: [TimeInterval] = [2, 5, 15]
    private static let checksumPrefix = "checksum-retry:"

    init(key: String, retryCount: Int = 0, usesMirror: Bool = false, retriedChecksum: Bool = false) {
        self.key = key
        self.retryCount = retryCount
        self.usesMirror = usesMirror
        self.retriedChecksum = retriedChecksum
    }

    init?(description: String?) {
        guard let description, !description.isEmpty else { return nil }
        let retriedChecksum = description.hasPrefix(Self.checksumPrefix)
        let payload = description.dropFirst(retriedChecksum ? Self.checksumPrefix.count : 0)
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false)
        guard let key = parts.first, !key.isEmpty else { return nil }
        if parts.count == 1 {
            self.init(key: String(key), retriedChecksum: retriedChecksum)
        } else {
            guard let count = Int(parts[1]), (0...Self.delays.count).contains(count) else { return nil }
            let mirror = parts.count == 3 && parts[2] == "mirror"
            guard mirror || (parts.count == 2 && count > 0) else { return nil }
            self.init(key: String(key), retryCount: count, usesMirror: mirror, retriedChecksum: retriedChecksum)
        }
    }

    var taskDescription: String {
        let payload = if usesMirror {
            "\(key)|\(retryCount)|mirror"
        } else {
            retryCount == 0 ? key : "\(key)|\(retryCount)"
        }
        return retriedChecksum ? Self.checksumPrefix + payload : payload
    }

    var transportRetry: Self {
        Self(key: key, retryCount: retryCount + 1, usesMirror: usesMirror, retriedChecksum: retriedChecksum)
    }

    var checksumRetry: Self? {
        retriedChecksum ? nil : Self(key: key, usesMirror: usesMirror, retriedChecksum: true)
    }

    var mirror: Self { Self(key: key, usesMirror: true, retriedChecksum: retriedChecksum) }

    func canTryMirror(for error: NSError) -> Bool {
        guard !usesMirror, error.domain == NSURLErrorDomain else { return false }
        switch URLError.Code(rawValue: error.code) {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return true
        default: return false
        }
    }

    func canTryMirror(for response: HTTPURLResponse) -> Bool {
        !usesMirror && [404, 410, 408, 500, 502, 503, 504].contains(response.statusCode)
    }

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
    @Published private var publisherApprovals: [String: KiwixDownloadApproval]
    @Published private var installedPublisherArchives: [UUID: InstalledArchive] = [:]

    var publisherDownloads: [PublishedPack] {
        publisherApprovals.values.map(\.pack).sorted { ($0.title, $0.editionKey) < ($1.title, $1.editionKey) }
    }

    var downloadAllSizeEstimate: Int64 {
        sizeEstimate(for: Self.defaultPacks)
    }

    var essentialsSizeEstimate: Int64 { sizeEstimate(for: Self.essentials) }

    private let library = InstalledLibrary.standard
    private let staging: URL
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

    private init() {
        let staging = URL.applicationSupportDirectory.appendingPathComponent("PackDownloads", isDirectory: true)
        self.staging = staging
        publisherApprovals = KiwixDownloadApproval.load(from: staging)
    }

    func publisherEdition(for pack: PublishedPack) -> PublishedPack {
        Self.catalog.first { $0.sha256 == pack.sha256 && $0.sizeEstimate == pack.sizeEstimate }
            ?? publisherApprovals[pack.editionKey]?.pack ?? pack
    }

    func publisherFileImported(_ archive: InstalledArchive, as pack: PublishedPack) {
        guard canStart(pack) else { return }
        transfer.clearResume(pack.editionKey)
        installedPublisherArchives[archive.id] = archive
        statuses[pack.editionKey] = .installed
    }

    func status(for pack: PublishedPack) -> Status? {
        let status = statuses[pack.editionKey]
        switch status {
        case .downloading, .retrying, .pausing, .verifying, .installed: return status
        default: break
        }
        guard KiwixDownloadApproval.isValid(pack), installedPublisherArchives.values.contains(where: {
            $0.pack?.sha256 == pack.sha256 && $0.byteCount == pack.sizeEstimate
        }) else { return status }
        return .installed
    }

    private func pack(for key: String) -> PublishedPack? {
        Self.catalog.first { $0.editionKey == key } ?? publisherApprovals[key]?.pack
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
        for archive in installed where archive.pack != nil {
            installedPublisherArchives[archive.id] = archive
        }
        for pack in Self.catalog + publisherDownloads {
            let key = pack.editionKey
            if tasks[key] != nil { continue }
            if case .verifying = statuses[key] { continue }
            let repair = repairTarget(key)
            let update = updateTarget(key)
            if repair == nil, let current = installed.first(where: { archive in
                archive.pack == pack || (publisherApprovals[key] != nil && archive.pack?.sha256 == pack.sha256
                    && archive.byteCount == pack.sizeEstimate)
            }),
               update == nil || current.replacesArchiveID == update {
                if update != nil { try? FileManager.default.removeItem(at: updateURL(key)) }
                transfer.discardDownload(key)
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
            } else if repair != nil || update != nil || publisherApprovals[key] != nil {
                statuses[key] = .failed("The download was interrupted. Retry to continue.")
            }
        }
    }

    func start(_ pack: PublishedPack, network: PackDownloadNetwork? = nil) {
        guard !restoring, canStart(pack) else { return }
        let key = pack.editionKey
        let publisher = !Self.catalog.contains(pack)
        let selectedNetwork = network ?? preferredNetwork(for: pack)
        downloadAllError = nil
        do {
            if publisher {
                let approval = KiwixDownloadApproval(pack: pack, allowsCellular: selectedNetwork == .cellularAllowed)
                try approval.save(in: staging)
                publisherApprovals[key] = approval
            }
            try enqueue([pack], network: selectedNetwork)
        } catch {
            statuses[key] = .failed(error.localizedDescription)
        }
    }

    func canInstallLocalCopy(_ pack: PublishedPack) -> Bool {
        let key = pack.editionKey
        return !restoring && canStart(pack) && updateTarget(key) == nil && repairTarget(key) == nil
    }

    func installLocalCopy(_ match: PortableLibraryFolder.Match, progress: @escaping @Sendable (Double) -> Void) async throws {
        let pack = match.pack
        let key = pack.editionKey
        guard Self.catalog.contains(pack), canInstallLocalCopy(pack) else {
            throw LocalCopyUnavailable()
        }
        try await installLocalEdition(key: key) {
            try await library.installPack(pack, from: match.file, progress: progress)
        }
    }

    func installNearbyArchive(_ pack: PublishedPack, from file: URL) async throws {
        guard Self.allowsArchiveSharing(pack), canInstallLocalCopy(pack) else { throw LocalCopyUnavailable() }
        try await installLocalEdition(key: pack.editionKey) {
            try await library.installDownloadedPublishedPack(pack, from: file)
        }
    }

    private func installLocalEdition(key: String, install: () async throws -> InstalledArchive) async throws {
        let previous = statuses[key]
        statuses[key] = .verifying
        do {
            let archive = try await install()
            installedPublisherArchives[archive.id] = archive
            transfer.clearResume(key)
            try? FileManager.default.removeItem(at: transfer.downloadURL(key))
            statuses[key] = .installed
            installedRevision += 1
        } catch {
            statuses[key] = previous
            throw error
        }
    }

    private struct LocalCopyUnavailable: LocalizedError {
        var errorDescription: String? { "This edition is already installed or has an archive operation in progress." }
    }

    func allowsCellular(for pack: PublishedPack) -> Bool {
        tasks[pack.editionKey]?.network == .cellularAllowed
    }

    func resumesOnCellular(for pack: PublishedPack) -> Bool {
        preferredNetwork(for: pack) == .cellularAllowed
    }

    private func preferredNetwork(for pack: PublishedPack) -> PackDownloadNetwork {
        if let approval = publisherApprovals[pack.editionKey] {
            return approval.allowsCellular ? .cellularAllowed : .wifiOnly
        }
        return transfer.resumeNetwork(pack.editionKey)
    }

    func activeMirrorHost(for pack: PublishedPack) -> String? {
        guard let task = tasks[pack.editionKey]?.task,
              PackDownloadAttempt(description: task.taskDescription)?.usesMirror == true else { return nil }
        return PackCatalog.fallbackMirror(for: pack)?.host
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
        installedPublisherArchives[archive.id] = nil
        let key = pack.editionKey
        let completedApprovals = publisherApprovals.values.filter {
            guard $0.pack.sha256 == pack.sha256, $0.pack.sizeEstimate == archive.byteCount,
                  case .installed = statuses[$0.pack.editionKey] else { return false }
            return true
        }
        for approval in completedApprovals {
            try? approval.remove(from: staging)
            publisherApprovals[approval.pack.editionKey] = nil
            statuses[approval.pack.editionKey] = nil
        }
        if repairTarget(key) == archive.id {
            try? FileManager.default.removeItem(at: repairURL(key))
            transfer.clearResume(key)
            transfer.discardDownload(key)
            statuses[key] = nil
        } else if case .installed = statuses[key] {
            statuses[key] = nil
        }
        for replacement in Self.catalog where updateTarget(replacement.editionKey) == archive.id {
            let updateKey = replacement.editionKey
            tasks.removeValue(forKey: updateKey)?.task.cancel()
            try? FileManager.default.removeItem(at: updateURL(updateKey))
            transfer.clearResume(updateKey)
            transfer.discardDownload(updateKey)
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
        switch status(for: pack) {
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
        let reservedBytes = (Self.catalog + publisherDownloads).reduce(Int64.zero) { total, pack in
            let key = pack.editionKey
            switch statuses[key] {
            case .downloading, .retrying:
                let received = max(0, tasks[key]?.task.countOfBytesReceived ?? 0)
                return Self.addingCapacity(total, capacityEstimate(for: pack) - min(received, pack.sizeEstimate))
            case .verifying:
                return Self.addingCapacity(total, capacityEstimate(for: pack) - pack.sizeEstimate)
            default:
                return total
            }
        }
        let required = Self.addingCapacity(Self.addingCapacity(downloadAndIndexBytes, reservedBytes), 64 * 1024 * 1024)
        if let bytes = available.volumeAvailableCapacityForImportantUsage, bytes < required {
            throw InsufficientStorage(shortfall: required - bytes)
        }
        for pack in packs {
            let key = pack.editionKey
            let usesMirror = PackCatalog.fallbackMirror(for: pack) != nil
                && transfer.hasMirrorResume(key, network: network)
            let previous = transfer.verificationContext(key)
            let previousAttempt = previous?.attempt(for: key)
            let resumedChecksumRetry = transfer.hasResume(key, network: network) && previous?.network == network
                && previousAttempt?.usesMirror == usesMirror && previousAttempt?.retriedChecksum == true
            let attempt = PackDownloadAttempt(key: key, usesMirror: usesMirror, retriedChecksum: resumedChecksumRetry)
            beginDownload(pack, network: network, attempt: attempt)
        }
    }

    private static func addingCapacity(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private func beginDownload(_ pack: PublishedPack, network: PackDownloadNetwork, attempt: PackDownloadAttempt,
                               delay: TimeInterval? = nil) {
        let source = attempt.usesMirror ? PackCatalog.fallbackMirror(for: pack) : pack.source
        guard let source else {
            statuses[attempt.key] = .failed("This edition’s mirror is no longer in the catalog.")
            return
        }
        do {
            let verification = PackTransfer.VerificationContext(attempt: attempt, network: network, host: nil)
            try transfer.recordVerification(verification, key: attempt.key)
        } catch {
            statuses[attempt.key] = .failed(error.localizedDescription)
            return
        }
        let session = transfer.session(for: network)
        let resumeURL = transfer.resumeURL(attempt.key, network: network, usesMirror: attempt.usesMirror)
        let task: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: resumeURL) {
            task = session.downloadTask(withResumeData: resume)
        } else {
            task = session.downloadTask(with: source)
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
        let usesMirror = PackDownloadAttempt(description: active.task.taskDescription)?.usesMirror == true
        statuses[key] = .pausing
        active.task.cancel { [weak self] resumeData in
            Task { @MainActor in
                guard let self else { return }
                if let resumeData {
                    try? self.transfer.saveResume(resumeData, key: key, network: active.network, usesMirror: usesMirror)
                }
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
            guard accepts(ticket), let pack = pack(for: ticket.key) else { return }
            let key = ticket.key
            tasks[key] = nil
            install(pack)
        case let .failed(ticket, message, delay, canTryMirror):
            let key = ticket.key
            guard accepts(ticket), let pack = pack(for: key), tasks[key] != nil || restoring else { return }
            tasks[key] = nil
            switch statuses[key] {
            case .pausing, .paused, .verifying, .installed: break
            default:
                if let delay {
                    beginDownload(pack, network: ticket.network, attempt: ticket.attempt.transportRetry, delay: delay)
                } else if canTryMirror, PackCatalog.fallbackMirror(for: pack) != nil {
                    // Resume data belongs to the origin and must not carry over to the mirror.
                    transfer.clearResume(key)
                    beginDownload(pack, network: ticket.network, attempt: ticket.attempt.mirror)
                } else if ticket.attempt.usesMirror, let host = PackCatalog.fallbackMirror(for: pack)?.host {
                    statuses[key] = .failed("Mirror \(host) could not provide the archive. \(message)")
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
        let verification = transfer.verificationContext(key)
        Task {
            do {
                if let archiveID = repairTarget(key) {
                    try await library.repairPack(pack, archiveID: archiveID, from: file, movingSource: true)
                    try FileManager.default.removeItem(at: repairURL(key))
                } else if publisherApprovals[key] != nil {
                    let archive = try await library.installDownloadedPublishedPack(pack, from: file)
                    installedPublisherArchives[archive.id] = archive
                } else {
                    let archive = try await library.installPack(pack, from: file, replacing: updateTarget(key), movingSource: true)
                    installedPublisherArchives[archive.id] = archive
                    try? FileManager.default.removeItem(at: updateURL(key))
                }
                transfer.discardDownload(key)
                transfer.clearResume(key)
                statuses[key] = .installed
                installedRevision += 1
            } catch let error as InstalledLibrary.PublisherChecksumMismatch {
                // Never carry partial bytes from a transfer that failed verification.
                transfer.discardDownload(key)
                transfer.clearResume(key)
                guard case .verifying = statuses[key] else { return }
                if let verification, let retry = verification.attempt(for: key)?.checksumRetry,
                   !FileManager.default.fileExists(atPath: file.path), !transfer.hasResume(key) {
                    beginDownload(pack, network: verification.network, attempt: retry)
                } else {
                    statuses[key] = .failed(verification?.failureMessage ?? error.localizedDescription)
                }
            } catch {
                transfer.discardDownload(key)
                transfer.clearResume(key)
                statuses[key] = .failed(error.localizedDescription)
            }
        }
    }
}

final class PackTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct VerificationContext: Codable, Sendable {
        let network: PackDownloadNetwork
        let host: String?
        private let attemptDescription: String

        init(attempt: PackDownloadAttempt, network: PackDownloadNetwork, host: String?) {
            attemptDescription = attempt.taskDescription
            self.network = network
            self.host = host
        }

        func attempt(for key: String) -> PackDownloadAttempt? {
            guard let attempt = PackDownloadAttempt(description: attemptDescription), attempt.key == key else { return nil }
            return attempt
        }

        var failureMessage: String? {
            host.map { "The download from \($0) does not match the publisher’s checksum." }
        }
    }

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
        case failed(Ticket, String, retryAfter: TimeInterval?, canTryMirror: Bool = false)
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

    private func verificationURL(_ key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("verification")
    }

    func verificationContext(_ key: String) -> VerificationContext? {
        guard let data = try? Data(contentsOf: verificationURL(key)) else { return nil }
        return try? JSONDecoder().decode(VerificationContext.self, from: data)
    }

    func recordVerification(_ verification: VerificationContext, key: String) throws {
        try JSONEncoder().encode(verification).write(to: verificationURL(key), options: .atomic)
    }

    func discardDownload(_ key: String) {
        try? FileManager.default.removeItem(at: downloadURL(key))
        try? FileManager.default.removeItem(at: verificationURL(key))
    }

    func stageDownload(at location: URL, key: String, verification: VerificationContext) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = downloadURL(key)
        guard !FileManager.default.fileExists(atPath: staged.path) else { return }
        try recordVerification(verification, key: key)
        try FileManager.default.moveItem(at: location, to: staged)
    }

    func resumeURL(_ key: String, network: PackDownloadNetwork, usesMirror: Bool = false) -> URL {
        let suffix = usesMirror ? "mirror-\(network.resumeExtension)" : network.resumeExtension
        return directory.appendingPathComponent(key).appendingPathExtension(suffix)
    }

    func hasResume(_ key: String) -> Bool {
        PackDownloadNetwork.allCases.contains { hasResume(key, network: $0) }
    }

    func hasResume(_ key: String, network: PackDownloadNetwork) -> Bool {
        FileManager.default.fileExists(atPath: resumeURL(key, network: network).path)
            || hasMirrorResume(key, network: network)
    }

    func hasMirrorResume(_ key: String, network: PackDownloadNetwork) -> Bool {
        FileManager.default.fileExists(atPath: resumeURL(key, network: network, usesMirror: true).path)
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
            try? FileManager.default.removeItem(at: resumeURL(key, network: network, usesMirror: true))
        }
    }

    func saveResume(_ data: Data, key: String, network: PackDownloadNetwork, usesMirror: Bool = false) throws {
        try data.write(to: resumeURL(key, network: network, usesMirror: usesMirror), options: .atomic)
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
                         retryAfter: ticket.attempt.retryDelay(for: response),
                         canTryMirror: ticket.attempt.canTryMirror(for: response)))
            return
        }
        do {
            let verification = VerificationContext(attempt: ticket.attempt, network: ticket.network, host: response.url?.host)
            try stageDownload(at: location, key: ticket.key, verification: verification)
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
            try? saveResume(data, key: ticket.key, network: ticket.network, usesMirror: ticket.attempt.usesMirror)
        }
        post(.failed(ticket, error.localizedDescription, retryAfter: ticket.attempt.retryDelay(for: error),
                     canTryMirror: ticket.attempt.canTryMirror(for: error)))
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
