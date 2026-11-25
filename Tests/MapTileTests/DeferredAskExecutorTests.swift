import Foundation
import XCTest
@testable import TinfoilKit

final class DeferredAskExecutorTests: XCTestCase {
    func testRelaunchRecognizesCommittedAnswerWithoutSendingAgain() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DeferredAskQueue(directory: directory)
        let queued = try await queue.enqueue(question: "Which office issues the notices?", provider: .gpt, allowMetered: false)
        _ = try await queue.claim(queued.id, now: .now)
        let cache = FixtureCache()
        await cache.save(OnlineAskSavedAnswer(id: queued.id, provider: queued.provider, question: queued.question,
                                             answer: "Fixture result", sources: []))

        let reopened = DeferredAskQueue(directory: directory)
        let worker = executor(reopened, cache: cache) { _, _ in
            XCTFail("Recovery must not issue a provider request")
            throw URLError(.cancelled)
        }
        try await worker.recoverInterruptedJobs()
        let restored = try await reopened.jobs()
        XCTAssertEqual(restored.first?.state, .saved)

        let interrupted = try await reopened.enqueue(question: "Unconfirmed request", provider: .claude, allowMetered: true)
        _ = try await reopened.claim(interrupted.id, now: .now)
        try await worker.recoverInterruptedJobs()
        let recovered = try await reopened.jobs()
        XCTAssertEqual(recovered.first(where: { $0.id == interrupted.id })?.state, .retryRequired)
    }

    func testNoConnectionSchedulesRetryButTimeoutRequiresConfirmation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DeferredAskQueue(directory: directory)
        let now = Date.now
        let job = try await queue.enqueue(question: "Find today’s official notice", provider: .claude, allowMetered: true)
        let first = try await queue.claim(job.id, now: now)
        try await executor(queue) { _, _ in throw URLError(.notConnectedToInternet) }
            .perform(XCTUnwrap(first), now: { now })
        let scheduled = try await queue.jobs()
        XCTAssertEqual(scheduled.first?.state, .queued)
        XCTAssertEqual(scheduled.first?.nextAttemptAt, now.addingTimeInterval(60))
        let early = try await queue.claim(job.id, now: now.addingTimeInterval(59))
        XCTAssertNil(early)
        let second = try await queue.claim(job.id, now: now.addingTimeInterval(60))
        try await executor(queue) { _, _ in throw URLError(.timedOut) }.perform(XCTUnwrap(second))
        let uncertain = try await queue.jobs()
        XCTAssertEqual(uncertain.first?.state, .retryRequired)
    }

    func testCancellationPreventsPublishingALateReply() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DeferredAskQueue(directory: directory)
        let cache = FixtureCache()
        let job = try await queue.enqueue(question: "Find the agency’s notice", provider: .gpt, allowMetered: false)
        let claim = try await queue.claim(job.id, now: .now)
        let worker = executor(queue, cache: cache) { request, _ in
            try await queue.cancel(request.id)
            return OnlineAskResponse(answer: "Late response", citations: [])
        }
        try await worker.perform(XCTUnwrap(claim))
        let records = try await queue.jobs()
        let saved = await cache.answer(job.id)
        XCTAssertEqual(records.first?.state, .cancelled)
        XCTAssertNil(saved)
    }

    func testDeferredReplySavesExactQuestionAndCitationsUnderJobID() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DeferredAskQueue(directory: directory)
        let cache = FixtureCache()
        let job = try await queue.enqueue(question: "Find the official forecast", provider: .claude, allowMetered: false)
        let claim = try await queue.claim(job.id, now: .now)
        let citation = OnlineAskCitation(url: URL(string: "https://www.weather.gov/")!, title: "NWS", excerpt: nil)
        let worker = executor(queue, cache: cache) { request, key in
            XCTAssertEqual(request.question, job.question)
            XCTAssertEqual(request.provider, job.provider)
            XCTAssertFalse(request.allowMetered)
            XCTAssertEqual(key, "fixture-key")
            return OnlineAskResponse(answer: "Fixture [1]", citations: [citation])
        }
        try await worker.perform(XCTUnwrap(claim))
        let storedAnswer = await cache.answer(job.id)
        let saved = try XCTUnwrap(storedAnswer)
        let jobs = try await queue.jobs()
        XCTAssertEqual(saved.id, job.id)
        XCTAssertEqual(saved.sources.map(\.citation), [citation])
        XCTAssertEqual(jobs.first?.state, .saved)
    }

    private func executor(_ queue: DeferredAskQueue, cache: FixtureCache = FixtureCache(),
                          request: @escaping @Sendable (DeferredAskJob, String) async throws -> OnlineAskResponse)
        -> DeferredAskExecutor {
        DeferredAskExecutor(queue: queue, accessKey: { _ in "fixture-key" }, request: request,
                            answer: { await cache.answer($0) }, save: { await cache.save($0) },
                            removeAnswer: { await cache.remove($0) })
    }

    private func temporaryDirectory() -> URL { URL.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    private actor FixtureCache {
        var records: [UUID: OnlineAskSavedAnswer] = [:]
        func save(_ value: OnlineAskSavedAnswer) { records[value.id] = value }
        func answer(_ id: UUID) -> OnlineAskSavedAnswer? { records[id] }
        func remove(_ id: UUID) { records[id] = nil }
    }
}
