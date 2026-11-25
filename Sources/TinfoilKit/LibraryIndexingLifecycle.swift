import BackgroundTasks
import SwiftUI
import ZIMArchive

@MainActor
final class LibraryIndexingLifecycle {
    static let shared = LibraryIndexingLifecycle()
    static let identifier = "org.tinfoilkit.ios.library-indexing"

    let indexing = LibraryIndexing(library: .standard)
    private var foreground = false
    private var backgroundTask: BGProcessingTask?
    private var registered = false

    private init() {
        indexing.setProcessingAllowed(false)
    }

    func register() {
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.run(task)
            }
        }
    }

    func updatePhase(_ phase: ScenePhase) {
        switch phase {
        case .active: foreground = true
        case .background: foreground = false
        default: return
        }
        indexing.setProcessingAllowed(foreground || backgroundTask != nil)
        scheduleIfNeeded()
    }

    func scheduleIfNeeded() {
        guard registered else { return }
        if indexing.hasPendingIndexes {
            let request = BGProcessingTaskRequest(identifier: Self.identifier)
            // Indexing reads only installed files and should also work away from an outlet.
            request.requiresNetworkConnectivity = false
            request.requiresExternalPower = false
            try? BGTaskScheduler.shared.submit(request)
        } else if backgroundTask == nil {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        }
    }

    private func run(_ task: BGProcessingTask) {
        guard backgroundTask == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        backgroundTask = task
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                guard let task else { return }
                self?.finish(task, success: false)
            }
        }
        indexing.setProcessingAllowed(true)
        Task {
            await indexing.refresh()
            guard backgroundTask === task else { return }
            // Leave another request available in case this execution is interrupted.
            scheduleIfNeeded()
            await indexing.waitForProcessing()
            finish(task, success: !indexing.hasPendingIndexes && indexing.errors.isEmpty && indexing.refreshError == nil)
        }
    }

    private func finish(_ task: BGProcessingTask, success: Bool) {
        guard backgroundTask === task else { return }
        backgroundTask = nil
        indexing.setProcessingAllowed(foreground)
        scheduleIfNeeded()
        task.setTaskCompleted(success: success)
    }
}
