import Foundation

enum AskEvidence: Identifiable {
    case archive(SummarySource)
    case web(OnlineAskSavedSource, String)

    var id: String {
        switch self {
        case let .archive(source): source.id
        case let .web(source, _): "saved-source-\(source.id.absoluteString)"
        }
    }

    var title: String {
        switch self {
        case let .archive(source): source.match.title
        case let .web(source, _): source.citation.title
        }
    }

    var excerpt: String {
        switch self {
        case let .archive(source): source.match.excerpt
        case let .web(_, text): text
        }
    }

    var origin: String {
        switch self {
        case let .archive(source): source.archive.title
        case let .web(source, _): source.resolvedURL?.host ?? source.citation.url.host ?? "Saved web source"
        }
    }

    static func combine(_ local: [SummarySource], savedAnswers: [OnlineAskSavedAnswer],
                        savedWebSources: [OnlineAskSavedSource], question: String) -> [Self] {
        let keywords = OnlineAskCache.words(question)
        var seen: Set<URL> = []
        var cached: [Self] = savedWebSources.compactMap { source in
            guard let text = source.text, let fragment = bestFragment(text, keywords: keywords), fragment.score > 0,
                  seen.insert(source.id).inserted else { return nil }
            return .web(source, fragment.text)
        }
        for entry in savedAnswers {
            let candidates = entry.sources.compactMap { source -> (OnlineAskSavedSource, Fragment)? in
                guard let excerpt = source.text,
                      let fragment = bestFragment(excerpt, keywords: keywords), fragment.score > 0 else { return nil }
                return (source, fragment)
            }.sorted { $0.1.score > $1.1.score }
            if let (source, fragment) = candidates.first(where: { !seen.contains($0.0.id) }) {
                seen.insert(source.id)
                cached.append(.web(source, fragment.text))
            }
        }
        let locallyIndexed = local.map(Self.archive)
        return Array(locallyIndexed.prefix(4)) + cached + Array(locallyIndexed.dropFirst(4))
    }

    private struct Fragment {
        let text: String
        let score: Int
    }

    private static func bestFragment(_ text: String, keywords: Set<String>) -> Fragment? {
        let clean = text.replacingOccurrences(of: #"\[([^\]]*)\]\(https?://[^)]+\)"#,
                                             with: "$1", options: .regularExpression)
        let parts = clean.split(whereSeparator: \.isNewline)
        var best: Fragment?
        for part in parts {
            let words = part.split(whereSeparator: \.isWhitespace)
            for start in stride(from: 0, to: words.count, by: 65) {
                let text = words[start..<min(start + 65, words.count)].joined(separator: " ")
                let score = keywords.intersection(OnlineAskCache.words(text)).count
                if best.map({ score > $0.score }) ?? true {
                    best = Fragment(text: text, score: score)
                }
            }
        }
        return best
    }
}
