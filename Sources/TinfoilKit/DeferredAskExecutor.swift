import Foundation

struct DeferredAskExecutor: Sendable {
    let queue: DeferredAskQueue
    let accessKey: @Sendable (OnlineAskProvider) throws -> String?
    let request: @Sendable (DeferredAskJob, String) async throws -> OnlineAskResponse
    let answer: @Sendable (UUID) async throws -> OnlineAskSavedAnswer?
    let save: @Sendable (OnlineAskSavedAnswer) async throws -> Void
    let removeAnswer: @Sendable (UUID) async throws -> Void

    func recoverInterruptedJobs() async throws {
        for job in try await queue.jobs() {
            switch job.state {
            case .running:
                if try await hasCommittedAnswer(for: job) {
                    try await queue.finish(job.id, state: .saved)
                } else {
                    try await queue.finish(job.id, state: .retryRequired,
                                           note: "The app closed before confirming this request. Retry only if you want to send it again.")
                }
            case .cancelled:
                try await removeAnswer(job.id)
            default:
                break
            }
        }
    }

    func perform(_ job: DeferredAskJob, now: @Sendable () -> Date = { .now }) async throws {
        guard try await isRunning(job.id) else { return }
        do {
            try Task.checkCancellation()
            guard let key = try accessKey(job.provider) else {
                try await queue.finish(job.id, state: .retryRequired,
                                       note: "Add the provider’s API key before retrying.")
                return
            }
            let result = try await request(job, key)
            try Task.checkCancellation()
            guard try await isRunning(job.id) else { return }
            guard result.cacheAllowed else {
                try await queue.finish(job.id, state: .retryRequired,
                                       note: "The provider’s response could not be saved for offline use.")
                return
            }
            let sources = result.citations.map { OnlineAskSavedSource(citation: $0, resolvedURL: nil, text: nil, note: nil) }
            try await save(OnlineAskSavedAnswer(id: job.id, savedAt: now(), provider: job.provider,
                                                question: job.question, answer: result.answer, sources: sources))
            try await queue.finish(job.id, state: .saved)
            try await removeCancelledAnswer(job.id)
        } catch {
            guard try await isRunning(job.id) else {
                try await removeCancelledAnswer(job.id)
                return
            }
            if try await hasCommittedAnswer(for: job) {
                try await queue.finish(job.id, state: .saved)
            } else if let delay = retryDelay(for: error, attempts: job.attempts) {
                try await queue.finish(job.id, state: .queued, note: "The provider could not be reached. Will try again on an allowed connection.",
                                       nextAttemptAt: now().addingTimeInterval(delay))
            } else {
                try await queue.finish(job.id, state: .retryRequired,
                                       note: "A saved answer could not be confirmed. Retrying can send the question again and incur another charge.")
            }
        }
    }

    private func isRunning(_ id: UUID) async throws -> Bool {
        try await queue.jobs().first(where: { $0.id == id })?.state == .running
    }

    private func removeCancelledAnswer(_ id: UUID) async throws {
        if try await queue.jobs().first(where: { $0.id == id })?.state == .cancelled {
            try await removeAnswer(id)
        }
    }

    private func hasCommittedAnswer(for job: DeferredAskJob) async throws -> Bool {
        guard let saved = try await answer(job.id) else { return false }
        return saved.id == job.id && saved.question == job.question && saved.provider == job.provider
    }

    private func retryDelay(for error: Error, attempts: Int) -> TimeInterval? {
        guard (1...2).contains(attempts), let error = error as? URLError else { return nil }
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed:
            return attempts == 1 ? 60 : 300
        default:
            return nil
        }
    }
}
