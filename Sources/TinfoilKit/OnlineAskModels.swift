import CryptoKit
import Foundation

enum OnlineAskProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case gpt, claude, gemini

    var id: Self { self }

    var title: String {
        switch self {
        case .gpt: "GPT"
        case .claude: "Claude"
        case .gemini: "Google Gemini"
        }
    }

    var website: URL {
        switch self {
        case .gpt: URL(string: "https://chatgpt.com/")!
        case .claude: URL(string: "https://claude.ai/")!
        case .gemini: URL(string: "https://gemini.google.com/")!
        }
    }
}

enum OnlineAskWebSearch {
    static func googleURL(for question: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: question)]
        // Form-style query parsers interpret a bare plus as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

struct OnlineAskCitation: Codable, Hashable, Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let title: String
    let excerpt: String?
}

struct OnlineAskResponse: Sendable {
    let answer: String
    let citations: [OnlineAskCitation]
    var searchEntryPointHTML: String? = nil
    var cacheAllowed: Bool = true
}

struct OnlineAskSavedSource: Codable, Identifiable, Sendable {
    var id: URL { citation.url }
    let citation: OnlineAskCitation
    let resolvedURL: URL?
    let text: String?
    let note: String?
}

struct OnlineAskSavedAnswer: Codable, Identifiable, Sendable {
    var id = UUID()
    var savedAt = Date()
    let provider: OnlineAskProvider
    let question: String
    let answer: String
    let sources: [OnlineAskSavedSource]
}

actor OnlineAskCache {
    static let shared = OnlineAskCache(directory: URL.applicationSupportDirectory
        .appendingPathComponent("SavedOnlineAnswers", isDirectory: true))

    private let directory: URL

    init(directory: URL) { self.directory = directory }

    private var webSourcesDirectory: URL { directory.appendingPathComponent("WebSources", isDirectory: true) }

    func saveWebSource(_ source: OnlineAskSavedSource) throws {
        guard let body = source.text, !body.isEmpty else { return }
        try FileManager.default.createDirectory(at: webSourcesDirectory, withIntermediateDirectories: true)
        try prepareDirectory()
        try JSONEncoder().encode(source).write(to: webSourceFile(source.id),
                                               options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func removeWebSource(_ url: URL) throws {
        let file = webSourceFile(url)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    func webSources() throws -> [OnlineAskSavedSource] {
        guard FileManager.default.fileExists(atPath: webSourcesDirectory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: webSourcesDirectory, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        return try files.compactMap { file in
            try Task.checkCancellation()
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(OnlineAskSavedSource.self, from: data)
        }
    }

    func searchWebSources(_ question: String) throws -> [OnlineAskSavedSource] {
        let terms = Self.words(question)
        guard !terms.isEmpty else { return [] }
        return try webSources().compactMap { source -> (Int, OnlineAskSavedSource)? in
            try Task.checkCancellation()
            let titleMatches = terms.intersection(Self.words(source.citation.title)).count
            let bodyMatches = terms.intersection(Self.words(source.text ?? "")).count
            guard titleMatches + bodyMatches > 0 else { return nil }
            return (2 * titleMatches + bodyMatches, source)
        }.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1.id.absoluteString < rhs.1.id.absoluteString : lhs.0 > rhs.0
        }.prefix(4).map { $0.1 }
    }

    private func webSourceFile(_ url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return webSourcesDirectory.appendingPathComponent(digest).appendingPathExtension("json")
    }

    func save(_ answer: OnlineAskSavedAnswer) throws {
        try prepareDirectory()
        try JSONEncoder().encode(answer).write(
            to: answerFile(answer.id),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func updateSources(_ sources: [OnlineAskSavedSource], for id: UUID) throws -> Bool {
        try Task.checkCancellation()
        guard let existing = try answer(id), existing.sources.map(\.id) == sources.map(\.id) else { return false }
        try save(OnlineAskSavedAnswer(id: id, savedAt: existing.savedAt, provider: existing.provider,
                                      question: existing.question, answer: existing.answer, sources: sources))
        return true
    }

    func answer(_ id: UUID) throws -> OnlineAskSavedAnswer? {
        let file = answerFile(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(OnlineAskSavedAnswer.self, from: Data(contentsOf: file))
    }

    func removeAnswer(_ id: UUID) throws {
        let file = answerFile(id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    private func answerFile(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try folder.setResourceValues(resources)
    }

    func search(_ question: String) throws -> [OnlineAskSavedAnswer] {
        let terms = Self.words(question)
        guard !terms.isEmpty, FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        var results: [(score: Int, entry: OnlineAskSavedAnswer)] = []
        for file in files where file.pathExtension == "json" {
            try Task.checkCancellation()
            guard let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(OnlineAskSavedAnswer.self, from: data) else { continue }
            let questionTerms = Self.words(entry.question)
            if terms == questionTerms {
                results.append((100 + terms.count, entry))
            } else {
                let questionOverlap = terms.intersection(questionTerms).count
                var content = Self.words(entry.answer)
                for source in entry.sources {
                    content.formUnion(Self.words(source.citation.title))
                    content.formUnion(Self.words(source.citation.excerpt ?? ""))
                    if let text = source.text { content.formUnion(Self.words(text)) }
                }
                let overlap = terms.intersection(questionTerms.union(content)).count
                guard overlap >= min(terms.count, max(2, (terms.count + 2) / 3)) else { continue }
                results.append((questionOverlap * 5 + overlap, entry))
            }
            results.sort {
                $0.score == $1.score ? $0.entry.savedAt > $1.entry.savedAt : $0.score > $1.score
            }
            if results.count > 4 { results.removeLast() }
        }
        return results.map(\.entry)
    }

    nonisolated static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.lazy
            .filter { $0.count >= 3 && !filler.contains(String($0)) }.map(String.init))
    }

    private static let filler: Set<String> = [
        "about", "and", "are", "can", "could", "does", "for", "from", "had", "has", "have", "how",
        "our", "should", "that", "the", "their", "them", "there", "these", "this", "was", "were",
        "what", "when", "where", "which", "will", "with", "would", "you", "your"
    ]
}
