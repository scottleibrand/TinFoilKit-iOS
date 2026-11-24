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

    func save(_ answer: OnlineAskSavedAnswer) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try folder.setResourceValues(resources)
        try JSONEncoder().encode(answer).write(
            to: directory.appendingPathComponent(answer.id.uuidString).appendingPathExtension("json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
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
