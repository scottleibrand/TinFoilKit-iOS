import Combine
import Foundation
import Network

@MainActor
final class DeferredAskController: ObservableObject {
    @Published private(set) var jobs: [DeferredAskJob] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedContentRevision = 0
    @Published private(set) var configuredProviders: Set<OnlineAskProvider> = []

    private let queue: DeferredAskQueue
    private let cache: OnlineAskCache
    private let executor: DeferredAskExecutor
    private let monitorQueue = DispatchQueue(label: "org.tinfoilkit.ios.deferred-ask-path")
    private var monitor: NWPathMonitor?
    private var monitorID = UUID()
    private var connection: Connection?
    private var worker: Task<Void, Never>?
    private var needsDrain = false
    private var wakeup: Task<Void, Never>?
    private var active: (id: UUID, task: Task<Void, Error>)?
    private var sourceCapture: (job: DeferredAskJob, task: Task<Bool, Error>)?

    private struct Connection: Equatable, Sendable {
        let online: Bool
        let metered: Bool
    }

    init(queue: DeferredAskQueue = DeferredAskQueue(directory: URL.applicationSupportDirectory
        .appendingPathComponent("DeferredOnlineAsk", isDirectory: true)), cache: OnlineAskCache = .shared) {
        self.queue = queue
        self.cache = cache
        configuredProviders = Self.availableProviders()
        executor = DeferredAskExecutor(
            queue: queue,
            accessKey: { try OnlineAskKeys.key(for: $0) },
            request: { job, key in
                try await OnlineAskClient.ask(job.question, provider: job.provider, apiKey: key,
                                              allowMetered: job.allowMetered)
            },
            answer: { try await cache.answer($0) },
            save: { try await cache.save($0) },
            removeAnswer: { try await cache.removeAnswer($0) }
        )
    }

    func setForeground(_ foreground: Bool) {
        guard foreground else {
            monitor?.cancel()
            monitor = nil
            connection = nil
            sourceCapture?.task.cancel()
            wakeup?.cancel()
            wakeup = nil
            return
        }
        guard monitor == nil else { return }
        configuredProviders = Self.availableProviders()
        let monitor = NWPathMonitor()
        let id = UUID()
        self.monitor = monitor
        monitorID = id
        monitor.pathUpdateHandler = { [weak self] path in
            let next = Connection(online: path.status == .satisfied, metered: path.isExpensive || path.isConstrained)
            Task { @MainActor [weak self] in
                guard let self, self.monitor != nil, self.monitorID == id, self.connection != next else { return }
                self.connection = next
                if let capture = self.sourceCapture, !self.allowedConnection(for: capture.job) {
                    capture.task.cancel()
                }
                self.kick()
            }
        }
        monitor.start(queue: monitorQueue)
        kick()
    }

    func enqueue(question: String, provider: OnlineAskProvider, allowMetered: Bool) async throws {
        try await queue.enqueue(question: question, provider: provider, allowMetered: allowMetered)
        try await loadJobs()
        kick()
    }

    func cancel(_ id: UUID) async {
        do {
            try await queue.cancel(id)
            if active?.id == id { active?.task.cancel() }
            try await loadJobs()
            if jobs.first(where: { $0.id == id })?.state == .cancelled { try await cache.removeAnswer(id) }
            kick()
        } catch { errorMessage = error.localizedDescription }
    }

    func retry(_ id: UUID) async {
        do {
            try await queue.retry(id)
            try await loadJobs()
            kick()
        } catch { errorMessage = error.localizedDescription }
    }

    func remove(_ id: UUID) async {
        do {
            // Keep a cancellation record until the matching task has settled.
            if let active, active.id == id { _ = await active.task.result }
            try await queue.remove(id)
            try await loadJobs()
            kick()
        } catch { errorMessage = error.localizedDescription }
    }

    func savedAnswer(_ id: UUID) async throws -> OnlineAskSavedAnswer? {
        try await cache.answer(id)
    }

    func keysChanged() {
        configuredProviders = Self.availableProviders()
        kick()
    }

    private static func availableProviders() -> Set<OnlineAskProvider> {
        Set([OnlineAskProvider.gpt, .claude].filter { (try? OnlineAskKeys.key(for: $0)) != nil })
    }

    private func kick() {
        wakeup?.cancel()
        wakeup = nil
        guard monitor != nil else { return }
        guard worker == nil else {
            needsDrain = true
            return
        }
        needsDrain = false
        worker = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        defer {
            worker = nil
            if needsDrain { kick() }
        }
        do {
            try await executor.recoverInterruptedJobs()
            try await loadJobs()
            while let job = jobs.first(where: { allowed($0) && ($0.nextAttemptAt ?? .distantPast) <= .now }) {
                guard let claimed = try await queue.claim(job.id, now: .now) else {
                    try await loadJobs()
                    continue
                }
                guard allowedConnection(for: claimed) else {
                    try await queue.releaseUnsentClaim(claimed.id)
                    try await loadJobs()
                    continue
                }
                let executor = self.executor
                let task = Task { try await executor.perform(claimed) }
                active = (claimed.id, task)
                // Always await the task before releasing the single send slot.
                do { try await loadJobs() } catch { errorMessage = error.localizedDescription }
                let outcome = await task.result
                active = nil
                try outcome.get()
                try await loadJobs()
            }
            try await capturePendingSources()
            scheduleRetry()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func allowed(_ job: DeferredAskJob) -> Bool {
        job.state == .queued && configuredProviders.contains(job.provider) && allowedConnection(for: job)
    }

    private func allowedConnection(for job: DeferredAskJob) -> Bool {
        monitor != nil && connection?.online == true && (job.allowMetered || connection?.metered == false)
    }

    private func capturePendingSources() async throws {
        for job in jobs where job.state == .saved && allowedConnection(for: job) {
            guard !needsDrain else { return }
            guard let answer = try await cache.answer(job.id),
                  answer.sources.contains(where: { $0.text == nil && $0.note == nil }),
                  allowedConnection(for: job) else { continue }
            let cache = self.cache
            let task = Task(priority: .utility) {
                let sources = try await OnlineSourceArchiver.capture(answer.sources.map(\.citation),
                                                                     allowMetered: job.allowMetered)
                try Task.checkCancellation()
                return try await cache.updateSources(sources, for: job.id)
            }
            sourceCapture = (job, task)
            let result = await task.result
            sourceCapture = nil
            switch result {
            case .success(let updated):
                if updated { savedContentRevision += 1 }
            case .failure(is CancellationError):
                break
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleRetry() {
        guard let next = jobs.filter({ allowed($0) }).compactMap(\.nextAttemptAt).min() else { return }
        wakeup = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.25, next.timeIntervalSinceNow))) } catch { return }
            self?.kick()
        }
    }

    private func loadJobs() async throws {
        let updated = try await queue.jobs()
        let previousIDs = Set(jobs.filter { $0.state == .saved }.map(\.id))
        jobs = updated
        if jobs.contains(where: { $0.state == .saved && !previousIDs.contains($0.id) }) {
            savedContentRevision += 1
        }
        errorMessage = nil
    }
}
