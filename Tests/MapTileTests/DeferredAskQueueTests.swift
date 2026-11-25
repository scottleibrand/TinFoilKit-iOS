import Foundation
import XCTest
@testable import TinfoilKit

final class DeferredAskQueueTests: XCTestCase {
    func testPersistsExactTrimmedQuestionPolicyAndRunningStateAcrossReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DeferredAskQueue(directory: directory)
        let question = "Where can I find\n  the official utility notice?"
        let created = try await queue.enqueue(question: " \n" + question + " \n", provider: .claude, allowMetered: false)
        XCTAssertEqual(created.question, question)
        XCTAssertEqual(created.state, .queued)

        let now = Date()
        async let first = queue.claim(created.id, now: now)
        async let second = queue.claim(created.id, now: now)
        let (one, two) = try await (first, second)
        let claimed = [one, two].compactMap { $0 }
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(claimed.first?.attempts, 1)

        let reopened = DeferredAskQueue(directory: directory)
        let restored = try await reopened.jobs()
        XCTAssertEqual(restored, claimed)
        XCTAssertEqual(restored.first?.question, question)
        XCTAssertEqual(restored.first?.provider, .claude)
        XCTAssertEqual(restored.first?.allowMetered, false)
        XCTAssertEqual(restored.first?.state, .running)
        let duplicate = try await reopened.claim(created.id, now: now)
        XCTAssertNil(duplicate)
    }

    func testConnectionLossBeforeSendingDoesNotConsumeAnAttempt() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DeferredAskQueue(directory: directory)
        let job = try await queue.enqueue(question: "Where is the advisory?", provider: .gpt, allowMetered: false)
        _ = try await queue.claim(job.id, now: .now)
        try await queue.releaseUnsentClaim(job.id)
        let jobs = try await queue.jobs()
        XCTAssertEqual(jobs.first?.state, .queued)
        XCTAssertEqual(jobs.first?.attempts, 0)
    }

    func testScheduledAndExplicitRetryAreDifferentTransitions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DeferredAskQueue(directory: directory)
        let job = try await queue.enqueue(question: "Check the county notice", provider: .gpt, allowMetered: true)
        let start = Date()
        let first = try await queue.claim(job.id, now: start)
        XCTAssertEqual(first?.attempts, 1)

        let next = start.addingTimeInterval(60)
        try await queue.finish(job.id, state: .queued, note: "Try again later.", nextAttemptAt: next)
        try await queue.retry(job.id)
        let scheduled = try await queue.jobs()
        XCTAssertEqual(scheduled.first?.nextAttemptAt, next)
        XCTAssertEqual(scheduled.first?.note, "Try again later.")
        let early = try await queue.claim(job.id, now: next.addingTimeInterval(-1))
        XCTAssertNil(early)
        let due = try await queue.claim(job.id, now: next)
        XCTAssertEqual(due?.attempts, 2)
        XCTAssertNil(due?.nextAttemptAt)

        try await queue.finish(job.id, state: .retryRequired, note: "Check before retrying.")
        let promptRequired = try await queue.claim(job.id, now: next)
        XCTAssertNil(promptRequired)
        try await queue.retry(job.id)
        let approved = try await queue.claim(job.id, now: next)
        XCTAssertEqual(approved?.attempts, 3)
        XCTAssertEqual(approved?.allowMetered, true)
        XCTAssertNil(approved?.note)
    }

    func testCancelledAndRemovedJobsCannotBeOverwrittenByALateFinish() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DeferredAskQueue(directory: directory)
        let job = try await queue.enqueue(question: "Find the official notice", provider: .gpt, allowMetered: false)

        try await queue.remove(job.id)
        let beforeClaim = try await queue.jobs()
        XCTAssertEqual(beforeClaim.map(\.state), [.queued])
        _ = try await queue.claim(job.id, now: .now)
        try await queue.remove(job.id)
        let afterClaim = try await queue.jobs()
        XCTAssertEqual(afterClaim.map(\.state), [.running])

        try await queue.cancel(job.id)
        try await queue.finish(job.id, state: .saved)
        try await queue.retry(job.id)
        let afterFinish = try await queue.jobs()
        XCTAssertEqual(afterFinish.map(\.state), [.cancelled])
        try await queue.remove(job.id)
        try await queue.finish(job.id, state: .saved)
        let afterRemoval = try await queue.jobs()
        XCTAssertTrue(afterRemoval.isEmpty)
    }

    func testSavedStateAndQueueCap() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DeferredAskQueue(directory: directory)

        let next = try await queue.enqueue(question: "First question", provider: .gpt, allowMetered: false)
        for index in 1..<DeferredAskQueue.maximumJobs {
            try await queue.enqueue(question: "Question \(index)", provider: .claude, allowMetered: false)
        }
        do {
            try await queue.enqueue(question: "One too many", provider: .gpt, allowMetered: false)
            XCTFail("Expected queue cap")
        } catch {
            XCTAssertEqual(error as? DeferredAskQueue.QueueError, .full)
        }

        _ = try await queue.claim(next.id, now: .now)
        try await queue.finish(next.id, state: .saved)
        try await queue.cancel(next.id)
        let completed = try await queue.jobs().first { $0.id == next.id }
        XCTAssertEqual(completed?.state, .saved)
        try await queue.remove(next.id)
        let remaining = try await queue.jobs()
        XCTAssertEqual(remaining.count, DeferredAskQueue.maximumJobs - 1)
    }

    func testRejectsGeminiBlankAndOversizedQuestionsWithoutCreatingStorage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DeferredAskQueue(directory: directory)
        let permitted = "Check the source"
        let invalid: [(String, OnlineAskProvider, DeferredAskQueue.QueueError)] = [
            (permitted, .gemini, .unsupportedProvider),
            (" \n ", .gpt, .invalidQuestion),
            (String(repeating: "x", count: DeferredAskQueue.maximumQuestionLength + 1), .claude, .invalidQuestion)
        ]
        for (question, provider, expected) in invalid {
            do {
                try await queue.enqueue(question: question, provider: provider, allowMetered: false)
                XCTFail("Expected failure")
            } catch {
                XCTAssertEqual(error as? DeferredAskQueue.QueueError, expected)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testMalformedQueueIsNotSilentlyReplacedOnEnqueue() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("queue.json")
        let invalid = Data(#"{"schemaVersion":2,"jobs":[]}"#.utf8)
        try invalid.write(to: file)
        let queue = DeferredAskQueue(directory: directory)
        do {
            try await queue.enqueue(question: "Keep saved questions", provider: .gpt, allowMetered: false)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? DeferredAskQueue.QueueError, .invalidStorage)
        }
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }

    private func temporaryDirectory() -> URL {
        URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
