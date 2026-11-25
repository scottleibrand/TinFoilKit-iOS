import Foundation
import ZIMArchive

struct LibraryArchiveSearch {
    struct Output: Sendable {
        let matches: [SummarySource]
        let titleCache: [UUID: [ZIMArchive.ArticleTitle]]
        let unavailableCount: Int
    }

    static func search(
        _ query: String, in inputs: [(InstalledArchive, URL)], titleCache: [UUID: [ZIMArchive.ArticleTitle]]
    ) throws -> Output {
        try Task.checkCancellation()
        var textGroups: [[SummarySource]] = []
        var titleGroups: [[SummarySource]] = []
        var cachedTitles: [UUID: [ZIMArchive.ArticleTitle]] = [:]
        var unavailableCount = 0

        for (archive, url) in inputs {
            try Task.checkCancellation()
            var unavailable = false
            var textMatches: [ArticleIndex.Match] = []
            var seenPaths: Set<String> = []
            do {
                let index = ArticleIndex(archiveURL: url)
                textMatches = try index.search(query, includeIncomplete: true, prefixMatching: true)
                    .filter { seenPaths.insert($0.path).inserted }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                unavailable = true
            }
            textGroups.append(textMatches.map { SummarySource(archive: archive, match: $0) })

            var titles = titleCache[archive.id]
            let remaining = 30 - textMatches.count
            if query.count >= 2, remaining > 0 {
                if titles == nil {
                    do {
                        titles = try ZIMArchive(fileURL: url).articleTitles(matching: query)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        unavailable = true
                    }
                }
                let matches = (titles ?? []).filter { seenPaths.insert($0.path).inserted }.prefix(remaining)
                titleGroups.append(matches.map {
                    SummarySource(archive: archive,
                                  match: .init(path: $0.path, title: $0.title, excerpt: "", rank: 0))
                })
            }
            cachedTitles[archive.id] = titles
            if unavailable { unavailableCount += 1 }
        }

        try Task.checkCancellation()
        let indexed = LibraryResultOrder.interleave(textGroups, limit: 50)
        let fallback = LibraryResultOrder.interleave(titleGroups, limit: 50 - indexed.count)
        return Output(matches: indexed + fallback, titleCache: cachedTitles, unavailableCount: unavailableCount)
    }
}
