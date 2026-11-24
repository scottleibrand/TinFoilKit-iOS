import Foundation
import SwiftUI
import UIKit
import ZIMArchive

@MainActor
final class PackDownloads: ObservableObject {
    static let shared = PackDownloads()
    static let catalog = [
        wikipedia("climate-change", title: "Wikipedia Climate Change", size: 13_000_000,
                  hash: "dbcc313b4dd30cf7abbb1e6481c493d82937262158ea97624ca879a0bcf98b67"),
        wikipedia("chemistry", title: "Wikipedia Chemistry", size: 23_322_446,
                  hash: "560be082e8bb14cf3736489e680aa83b8f918b0ad00cc2a2adfe811844109259")
    ]

    @Published private(set) var statuses: [String: Status] = [:]
    @Published private(set) var restoring = true
    @Published private(set) var installedRevision = 0

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
            if installed.contains(where: { $0.pack == pack }) {
                statuses[key] = .installed
            } else if let task = sessionTasks.first(where: { $0.taskDescription == key }) as? URLSessionDownloadTask {
                tasks[key] = task
                statuses[key] = .downloading(nil)
            } else if FileManager.default.fileExists(atPath: transfer.downloadURL(key).path) {
                install(pack)
            } else if FileManager.default.fileExists(atPath: transfer.resumeURL(key).path) {
                statuses[key] = .paused
            }
        }
    }

    func start(_ pack: PublishedPack) {
        let key = pack.editionKey
        guard !restoring, tasks[key] == nil else { return }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var directory = staging
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let bytes = available.volumeAvailableCapacityForImportantUsage,
               bytes < pack.sizeEstimate * 2 + 64 * 1024 * 1024 {
                statuses[key] = .failed("Free more storage to download and index this pack.")
                return
            }
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
        } catch {
            statuses[key] = .failed(error.localizedDescription)
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
                try await library.installPack(pack, from: file)
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

    private static func wikipedia(_ topic: String, title: String, size: Int64, hash: String) -> PublishedPack {
        let version = "2026-10"
        let filename = "wikipedia_en_\(topic)_mini_\(version).zim"
        return PublishedPack(
            id: "wikipedia-en-\(topic)", title: title, version: version,
            source: URL(string: "https://download.kiwix.org/zim/wikipedia/\(filename)")!,
            sha256: hash, sizeEstimate: size, attribution: "Wikipedia contributors · CC BY-SA · Packaged by Kiwix"
        )
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
