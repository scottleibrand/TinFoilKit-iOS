import Foundation

struct DeferredAskJob: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, running, saved, retryRequired, cancelled
    }

    let id: UUID
    let question: String
    let provider: OnlineAskProvider
    let allowMetered: Bool
    let createdAt: Date
    var state: State
    var note: String?
    var nextAttemptAt: Date?
    var attempts: Int
}

/// Use one instance per directory. A persisted running job remains visible for the executor to reconcile.
actor DeferredAskQueue {
    static let maximumJobs = 64
    static let maximumQuestionLength = 500
    private static let maximumQuestionBytes = 4_096
    private static let maximumNoteBytes = 512
    private static let maximumFileBytes = 512 * 1024

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    enum QueueError: LocalizedError, Equatable {
        case invalidQuestion
        case unsupportedProvider
        case full
        case invalidTransition
        case invalidStorage

        var errorDescription: String? {
            switch self {
            case .invalidQuestion: "Enter a question of 500 characters or fewer."
            case .unsupportedProvider: "Only GPT and Claude questions can be queued."
            case .full: "The queue is full. Remove a finished question to add another."
            case .invalidTransition: "The queued question could not be updated."
            case .invalidStorage: "The saved question queue could not be verified."
            }
        }
    }

    private struct File: Codable {
        let schemaVersion: Int
        let jobs: [DeferredAskJob]
    }

    private var queueFile: URL { directory.appendingPathComponent("queue.json") }

    func jobs() throws -> [DeferredAskJob] {
        try read().sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
    }

    @discardableResult
    func enqueue(question: String, provider: OnlineAskProvider, allowMetered: Bool) throws -> DeferredAskJob {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidQuestion(question) else { throw QueueError.invalidQuestion }
        guard Self.supports(provider) else { throw QueueError.unsupportedProvider }

        var current = try read()
        guard current.count < Self.maximumJobs else { throw QueueError.full }
        let job = DeferredAskJob(id: UUID(), question: question, provider: provider,
                                 allowMetered: allowMetered, createdAt: Date(), state: .queued,
                                 note: nil, nextAttemptAt: nil, attempts: 0)
        current.append(job)
        try write(current)
        return job
    }

    func claim(_ id: UUID, now: Date) throws -> DeferredAskJob? {
        var current = try read()
        guard let index = current.firstIndex(where: { $0.id == id }), current[index].state == .queued,
              current[index].nextAttemptAt.map({ $0 <= now }) ?? true else { return nil }
        guard now.timeIntervalSinceReferenceDate.isFinite, current[index].attempts < Int.max else {
            throw QueueError.invalidTransition
        }
        current[index].state = .running
        current[index].attempts += 1
        current[index].note = nil
        current[index].nextAttemptAt = nil
        try write(current)
        return current[index]
    }

    func releaseUnsentClaim(_ id: UUID) throws {
        var current = try read()
        guard let index = current.firstIndex(where: { $0.id == id }),
              current[index].state == .running else { return }
        current[index].state = .queued
        current[index].attempts -= 1
        try write(current)
    }

    func finish(_ id: UUID, state: DeferredAskJob.State, note: String? = nil, nextAttemptAt: Date? = nil) throws {
        var current = try read()
        guard let index = current.firstIndex(where: { $0.id == id }), current[index].state == .running else { return }
        guard state != .running, nextAttemptAt == nil || state == .queued,
              nextAttemptAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              (note?.utf8.count ?? 0) <= Self.maximumNoteBytes else { throw QueueError.invalidTransition }

        current[index].state = state
        current[index].note = note
        current[index].nextAttemptAt = nextAttemptAt
        try write(current)
    }

    func cancel(_ id: UUID) throws {
        var current = try read()
        guard let index = current.firstIndex(where: { $0.id == id }),
              current[index].state != .saved, current[index].state != .cancelled else { return }
        current[index].state = .cancelled
        current[index].note = nil
        current[index].nextAttemptAt = nil
        try write(current)
    }

    func retry(_ id: UUID) throws {
        var current = try read()
        guard let index = current.firstIndex(where: { $0.id == id }),
              current[index].state == .retryRequired else { return }
        current[index].state = .queued
        current[index].note = nil
        current[index].nextAttemptAt = nil
        try write(current)
    }

    func remove(_ id: UUID) throws {
        var current = try read()
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        switch current[index].state {
        case .saved, .cancelled, .retryRequired:
            current.remove(at: index)
            try write(current)
        case .queued, .running:
            return
        }
    }

    private func read() throws -> [DeferredAskJob] {
        guard let folder = try attributes(at: directory) else { return [] }
        guard folder[.type] as? FileAttributeType == .typeDirectory else { throw QueueError.invalidStorage }
        guard let file = try attributes(at: queueFile) else { return [] }
        guard file[.type] as? FileAttributeType == .typeRegular,
              let size = (file[.size] as? NSNumber)?.intValue,
              (1...Self.maximumFileBytes).contains(size) else { throw QueueError.invalidStorage }

        let input = try FileHandle(forReadingFrom: queueFile)
        defer { try? input.close() }
        guard let bytes = try input.read(upToCount: Self.maximumFileBytes + 1), bytes.count == size,
              let decoded = try? JSONDecoder().decode(File.self, from: bytes),
              decoded.schemaVersion == 1, decoded.jobs.count <= Self.maximumJobs else {
            throw QueueError.invalidStorage
        }
        var ids = Set<UUID>()
        for job in decoded.jobs {
            guard ids.insert(job.id).inserted, Self.isValidQuestion(job.question), Self.supports(job.provider),
                  job.attempts >= 0, job.state != .running || job.attempts > 0,
                  job.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  (job.note?.utf8.count ?? 0) <= Self.maximumNoteBytes,
                  job.nextAttemptAt == nil || job.state == .queued,
                  job.nextAttemptAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
                throw QueueError.invalidStorage
            }
        }
        return decoded.jobs
    }

    private func write(_ jobs: [DeferredAskJob]) throws {
        let bytes = try JSONEncoder().encode(File(schemaVersion: 1, jobs: jobs))
        guard bytes.count <= Self.maximumFileBytes else { throw QueueError.full }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        try bytes.write(to: queueFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try bytes.write(to: queueFile, options: .atomic)
        #endif
        // Do not let the caller send a claimed question until the recorded transition has reached storage.
        let output = try FileHandle(forWritingTo: queueFile)
        defer { try? output.close() }
        try output.synchronize()
    }

    private func attributes(at url: URL) throws -> [FileAttributeKey: Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private static func supports(_ provider: OnlineAskProvider) -> Bool {
        switch provider {
        case .gpt, .claude: true
        case .gemini: false
        }
    }

    private static func isValidQuestion(_ question: String) -> Bool {
        !question.isEmpty && question.count <= maximumQuestionLength && question.utf8.count <= maximumQuestionBytes
            && question == question.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
