import Foundation
import ZIMArchive

struct SummarySource: Identifiable, Sendable {
    let archive: InstalledArchive
    let match: ArticleIndex.Match
    var id: String { "\(archive.id.uuidString)/\(match.path)" }
}

struct LibraryPassages: Sendable {
    let sources: [SummarySource]
    let unreadableArchives: Int

    static func search(
        question: String,
        suggestedQueries: [String] = [],
        archives: [InstalledArchive],
        library: InstalledLibrary
    ) async throws -> Self {
        var indexed: [(InstalledArchive, URL)] = []
        for archive in archives {
            try Task.checkCancellation()
            let file = await library.fileURL(for: archive.id)
            indexed.append((archive, file))
        }
        let inputs = indexed
        let queries = queries(for: question, suggested: suggestedQueries)
        let intent = SearchIntent(question)
        let task = Task.detached(priority: .userInitiated) {
            try search(queries: queries, intent: intent, indexed: inputs)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func search(
        queries: [String], intent: SearchIntent, indexed: [(InstalledArchive, URL)]
    ) throws -> Self {
        var candidates: [String: (source: SummarySource, score: Double)] = [:]
        var unreadable = 0
        for (archive, file) in indexed {
            try Task.checkCancellation()
            do {
                let index = ArticleIndex(archiveURL: file)
                for (queryOrder, query) in queries.enumerated() {
                    let matches = try index.search(query, passageWords: 64, includeIncomplete: true, prefixMatching: true)
                    add(matches, archive: archive, intent: intent, queryOrder: queryOrder, to: &candidates)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unreadable += 1
            }
        }
        let sources = candidates.values.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.source.id < rhs.source.id
        }.prefix(12).map(\.source)
        return Self(sources: sources, unreadableArchives: unreadable)
    }

    private static func add(
        _ matches: [ArticleIndex.Match], archive: InstalledArchive, intent: SearchIntent, queryOrder: Int,
        to candidates: inout [String: (source: SummarySource, score: Double)]
    ) {
        // A broad query may put single-topic passages ahead of the first useful match.
        let limit = intent.isWaterServiceOutage ? matches.count : min(matches.count, 8)
        for (rank, match) in matches.prefix(limit).enumerated() {
            guard let score = intent.score(match, rank: rank, queryOrder: queryOrder) else { continue }
            let source = SummarySource(archive: archive, match: match)
            if candidates[source.id].map({ $0.score >= score }) != true {
                candidates[source.id] = (source, score)
            }
        }
    }

    static func queries(for question: String, suggested: [String]) -> [String] {
        let original = words(in: question)
        let keywords = original.filter { !filler.contains($0.lowercased()) }
        let usable = keywords.isEmpty ? original : keywords
        let fallback: [String]
        if SearchIntent(question).isWaterServiceOutage {
            fallback = ["water power outage", "water backup power", "water power failure",
                        "water electricity", "pumping electricity", "water generator", "water blackout", "water power"]
        } else {
            // Keep a shorter query and single-term candidates for sparse indexes.
            fallback = [original.prefix(12).joined(separator: " "),
                        usable.prefix(5).joined(separator: " "),
                        usable.prefix(2).joined(separator: " ")]
                + usable.filter { $0.count > 1 }.suffix(8)
        }
        let cleanedSuggestions = suggested.compactMap { phrase -> String? in
            let terms = words(in: phrase)
            guard phrase.count <= 60, (1...4).contains(terms.count) else { return nil }
            return terms.joined(separator: " ")
        }.prefix(3)
        var seen: Set<String> = []
        return (Array(cleanedSuggestions) + fallback).filter { query in
            let normalized = query.lowercased().split(separator: " ").sorted().joined(separator: " ")
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }

    private static func words(in text: String) -> [String] {
        text.prefix(500).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    struct SearchIntent: Sendable {
        let isWaterServiceOutage: Bool
        private let topic: Set<String>

        init(_ question: String) {
            let terms = LibraryPassages.words(in: question).map { $0.lowercased() }
            topic = Set(terms).subtracting(LibraryPassages.filler)
            let hasService = Self.hasPhrase(Self.waterUtilityQuestion, in: terms)
                || (terms.contains("water") && Self.hasPhrase(["keep working", "still work", "stay on"], in: terms))
            let hasOutage = Self.hasPhrase(Self.powerInterruption, in: terms)
                || (terms.contains("outage") && !Set(terms).isDisjoint(with: ["power", "electrical", "electricity", "gridwide"]))
            isWaterServiceOutage = hasService && hasOutage
        }

        func score(_ match: ArticleIndex.Match, rank: Int, queryOrder: Int) -> Double? {
            guard !match.excerpt.isEmpty else { return nil }
            let title = LibraryPassages.words(in: match.title).map { $0.lowercased() }
            let excerpt = LibraryPassages.words(in: match.excerpt).map { $0.lowercased() }
            var relationshipScore = 0.0
            if isWaterServiceOutage {
                let serviceInExcerpt = Self.hasPhrase(Self.waterService, in: excerpt)
                let powerInExcerpt = Self.hasPhrase(Self.powerInterruption + Self.powerDependence, in: excerpt)
                guard powerInExcerpt, serviceInExcerpt || Self.hasPhrase(Self.waterService, in: title) else { return nil }
                relationshipScore = serviceInExcerpt ? 3 : 1
            }
            let titleOverlap = Double(topic.intersection(title).count)
            let excerptOverlap = Double(topic.intersection(excerpt).count)
            return relationshipScore + 2 * titleOverlap + 0.6 * excerptOverlap
                + 1 / Double(rank + 1) + 0.25 / Double(queryOrder + 1)
        }

        private static func hasPhrase(_ phrases: [String], in terms: [String]) -> Bool {
            let text = " " + terms.joined(separator: " ") + " "
            return phrases.contains { text.contains(" " + $0 + " ") }
        }

        private static let waterService = [
            "water system", "water systems", "water supply", "water service", "water utility", "water utilities",
            "drinking water", "potable water", "tap water", "water pressure", "water treatment",
            "water distribution", "water storage", "water pump", "water pumps", "pumping station", "pumping stations",
            "water mains", "reservoir", "reservoirs"
        ]
        private static let waterUtilityQuestion = [
            "water system", "water systems", "water supply", "water service", "water utility", "water utilities",
            "water pressure", "water distribution", "water pumps", "pumping stations", "water mains", "tap water"
        ]
        private static let powerInterruption = [
            "power outage", "power outages", "power failure", "power failures", "power loss", "loss of power",
            "lose power", "loses power", "lost power", "without power", "without electricity",
            "electricity outage", "electrical outage", "grid failure", "blackout", "blackouts",
            "electricity goes out", "power goes out"
        ]
        private static let powerDependence = [
            "backup power", "emergency power", "backup generator", "backup generators", "standby generator",
            "requires electricity", "require electricity", "depends on electricity", "electricity to pump"
        ]
    }

    private static let filler: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "can", "could", "did", "do", "does", "for", "from",
        "had", "has", "have", "how", "i", "if", "in", "is", "it", "long", "me", "my", "of", "on", "or", "our", "please",
        "should", "that", "the", "their", "this", "to", "was", "we", "were", "what", "when", "where", "which",
        "who", "why", "will", "with", "would", "you", "your"
    ]
}
