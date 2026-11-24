import Foundation
import PDFKit
import SQLite3
import SwiftSoup

public struct ArchivePDFReference: Sendable {
    public let path: String
    public let pageIndex: Int
    private static let prefix = "tinfoil-pdf-page:"

    var articlePath: String { "\(Self.prefix)\(pageIndex)/\(path)" }

    init(path: String, pageIndex: Int) {
        self.path = path
        self.pageIndex = pageIndex
    }

    public init?(articlePath: String) {
        guard articlePath.hasPrefix(Self.prefix) else { return nil }
        let rest = articlePath.dropFirst(Self.prefix.count)
        guard let separator = rest.firstIndex(of: "/"),
              let page = Int(rest[..<separator]), page >= 0 else { return nil }
        let path = String(rest[rest.index(after: separator)...])
        guard !path.isEmpty else { return nil }
        self.init(path: path, pageIndex: page)
    }
}

public struct ArticleIndex: Sendable {
    public struct Match: Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let title: String
        public let excerpt: String
        public let rank: Double

        public init(path: String, title: String, excerpt: String, rank: Double) {
            self.path = path
            self.title = title
            self.excerpt = excerpt
            self.rank = rank
        }
    }

    private let file: URL
    private var staging: URL {
        file.deletingLastPathComponent().appendingPathComponent(".articles-v2-in-progress.sqlite")
    }
    private var previousFiles: [URL] {
        let directory = file.deletingLastPathComponent()
        return ["articles-v1.sqlite", ".articles-v1-in-progress.sqlite"].map {
            directory.appendingPathComponent($0)
        }
    }
    private static let buildLock = NSLock()
    private static let publicationLock = NSLock()
    private static let batchSize: UInt32 = 256
    private static let minimumFreeBytes: UInt64 = 128 * 1024 * 1024
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(archiveURL: URL) {
        file = archiveURL.deletingLastPathComponent().appendingPathComponent("articles-v2.sqlite")
    }

    public var isReady: Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    public var hasSearchableIndex: Bool {
        ([staging] + previousFiles).contains { FileManager.default.fileExists(atPath: $0.path) } || isReady
    }

    /// Use a background task. Committed batches survive interruption and can be searched while building.
    public func build(
        archiveURL: URL,
        progress: (Double) -> Void = { _ in }
    ) throws {
        try Self.buildLock.withLock {
            try buildLocked(archiveURL: archiveURL, progress: progress)
        }
    }

    private func buildLocked(archiveURL: URL, progress: (Double) -> Void) throws {
        guard !isReady else { return }
        try Task.checkCancellation()
        let archive = try ZIMArchive(fileURL: archiveURL)
        let directory = file.deletingLastPathComponent()
        let total = archive.entryCount
        try checkFreeSpace(in: directory)
        do {
            try withDatabase(at: staging, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { db in
                try execute("BEGIN", on: db)
                try execute(
                    """
                    CREATE VIRTUAL TABLE IF NOT EXISTS articles USING fts5(
                        path UNINDEXED, title, body, label UNINDEXED, tokenize='unicode61 remove_diacritics 2'
                    )
                    """,
                    on: db
                )
                try execute("CREATE TABLE IF NOT EXISTS index_progress (next_entry INTEGER NOT NULL)", on: db)
                try execute("INSERT INTO index_progress SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM index_progress)", on: db)
                try execute("COMMIT", on: db)
                var cursor = try withStatement("SELECT next_entry FROM index_progress", on: db) { statement in
                    guard sqlite3_step(statement) == SQLITE_ROW else { throw error(for: db) }
                    let saved = sqlite3_column_int64(statement, 0)
                    guard (0...Int64(total)).contains(saved) else {
                        throw IndexError(message: "The saved search progress is invalid.", code: SQLITE_CORRUPT)
                    }
                    return UInt32(saved)
                }
                try withStatement("INSERT INTO articles(path, title, body, label) VALUES (?, ?, ?, ?)", on: db) { insert in
                    while cursor < total {
                        progress(Double(cursor) / Double(total))
                        try Task.checkCancellation()
                        try checkFreeSpace(in: directory)
                        let end = min(cursor + Self.batchSize, total)
                        try execute("BEGIN", on: db)
                        for index in cursor..<end {
                            try Task.checkCancellation()
                            try autoreleasepool {
                                try Self.indexEntry(at: index, in: archive) { path, title, body, label in
                                    try bind(path, at: 1, to: insert, on: db)
                                    try bind(title, at: 2, to: insert, on: db)
                                    try bind(body, at: 3, to: insert, on: db)
                                    try bind(label, at: 4, to: insert, on: db)
                                    guard sqlite3_step(insert) == SQLITE_DONE else { throw error(for: db) }
                                    sqlite3_reset(insert)
                                    sqlite3_clear_bindings(insert)
                                }
                            }
                        }
                        try execute("UPDATE index_progress SET next_entry = \(end)", on: db)
                        try execute("COMMIT", on: db)
                        cursor = end
                    }
                }
            }
        } catch let failure as IndexError {
            if failure.code == SQLITE_CORRUPT || failure.code == SQLITE_NOTADB {
                Self.publicationLock.withLock { try? FileManager.default.removeItem(at: staging) }
            }
            throw failure
        }
        try Self.publicationLock.withLock {
            try FileManager.default.moveItem(at: staging, to: file)
            for previous in previousFiles { try? FileManager.default.removeItem(at: previous) }
        }
        progress(1)
    }

    private static func indexEntry(
        at index: UInt32, in archive: ZIMArchive, add: (String, String, String, String) throws -> Void
    ) throws {
        if let article = try archive.article(at: index, maximumBytes: 512 * 1024) {
            let html = String(decoding: article.data, as: UTF8.self)
            try add(article.path, article.title, SwiftSoup.parse(html).body()?.text() ?? "", "")
            return
        }
        guard let entry = try archive.pdfEntry(at: index) else { return }
        guard let resource = try? archive.resource(at: entry.path),
              let document = PDFDocument(data: resource.data),
              document.pageCount > 0 else {
            let reference = ArchivePDFReference(path: entry.path, pageIndex: 0)
            try add(reference.articlePath, entry.title, "", entry.title)
            return
        }
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                let body = String(document.page(at: pageIndex)?.string?.prefix(512 * 1024) ?? "")
                guard pageIndex == 0 || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let reference = ArchivePDFReference(path: entry.path, pageIndex: pageIndex)
                // Index the title once so a title-only search opens the first page.
                try add(reference.articlePath, pageIndex == 0 ? entry.title : "", body,
                        "\(entry.title) · p. \(pageIndex + 1)")
            }
        }
    }

    private func checkFreeSpace(in directory: URL) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        if let available = attributes[.systemFreeSize] as? NSNumber,
           available.uint64Value < Self.minimumFreeBytes {
            throw IndexError(message: "Free up device storage and retry to continue indexing.", code: SQLITE_FULL)
        }
    }

    public func search(
        _ query: String, passageWords: Int = 22, includeIncomplete: Bool = false, prefixMatching: Bool = false
    ) throws -> [Match] {
        let tokens = prefixMatching
            ? query.split { !$0.isLetter && !$0.isNumber }.prefix(12)
            : query.split(whereSeparator: \.isWhitespace).prefix(12)
        guard !tokens.isEmpty else { return [] }
        let expression = tokens.map { token in
            let quoted = "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return prefixMatching && token.count >= 3 ? quoted + "*" : quoted
        }.joined(separator: " AND ")
        if isReady {
            return try searchIndex(at: file, expression: expression, passageWords: passageWords, hasLabels: true)
        }
        return try Self.publicationLock.withLock {
            try Task.checkCancellation()
            if isReady {
                return try searchIndex(at: file, expression: expression, passageWords: passageWords, hasLabels: true)
            }
            let staged = includeIncomplete
                ? try searchStagedIndex(at: staging, expression: expression, passageWords: passageWords, hasLabels: true)
                : []
            let previous = previousFiles[0]
            let older: [Match]
            if FileManager.default.fileExists(atPath: previous.path) {
                older = try searchIndex(at: previous, expression: expression, passageWords: passageWords, hasLabels: false)
            } else {
                older = includeIncomplete
                    ? try searchStagedIndex(at: previousFiles[1], expression: expression, passageWords: passageWords, hasLabels: false)
                    : []
            }
            var paths: Set<String> = []
            // Preserve ranked results from both indexes without comparing their independent scores.
            let combined = (0..<max(staged.count, older.count)).flatMap { position in
                [staged, older].compactMap { $0.indices.contains(position) ? $0[position] : nil }
            }
            return Array(combined.filter { paths.insert($0.path).inserted }.prefix(30))
        }
    }

    private func searchStagedIndex(
        at url: URL, expression: String, passageWords: Int, hasLabels: Bool
    ) throws -> [Match] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try searchIndex(at: url, expression: expression, passageWords: passageWords, hasLabels: hasLabels)
        } catch let failure as IndexError where failure.code == SQLITE_BUSY || failure.code == SQLITE_LOCKED
            || failure.code == SQLITE_ERROR {
            // The schema may still be in its first uncommitted transaction.
            return []
        }
    }

    private func searchIndex(
        at url: URL, expression: String, passageWords: Int, hasLabels: Bool
    ) throws -> [Match] {
        let title = hasLabels ? "coalesce(nullif(label, ''), title)" : "title"
        return try withDatabase(at: url, flags: SQLITE_OPEN_READONLY) { db in
            sqlite3_progress_handler(db, 1_000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            return try withStatement("""
                SELECT path, \(title), snippet(articles, 2, '', '', '…', ?), bm25(articles, 0.0, 4.0, 1.0)
                FROM articles WHERE articles MATCH ? ORDER BY 4 LIMIT 30
                """, on: db) { statement in
                guard sqlite3_bind_int(statement, 1, Int32(max(1, min(64, passageWords)))) == SQLITE_OK else {
                    throw error(for: db)
                }
                try bind(expression, at: 2, to: statement, on: db)
                var matches: [Match] = []
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    try Task.checkCancellation()
                    matches.append(Match(
                        path: String(cString: sqlite3_column_text(statement, 0)),
                        title: String(cString: sqlite3_column_text(statement, 1)),
                        excerpt: String(cString: sqlite3_column_text(statement, 2)),
                        rank: sqlite3_column_double(statement, 3)
                    ))
                    status = sqlite3_step(statement)
                }
                try Task.checkCancellation()
                guard status == SQLITE_DONE else { throw error(for: db) }
                return matches
            }
        }
    }

    private func withDatabase<T>(
        at url: URL, flags: Int32, _ operation: (OpaquePointer) throws -> T
    ) throws -> T {
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &connection, flags, nil)
        defer { sqlite3_close(connection) }
        guard status == SQLITE_OK, let connection else { throw error(for: connection) }
        sqlite3_busy_timeout(connection, flags == SQLITE_OPEN_READONLY ? 300 : 5_000)
        return try operation(connection)
    }

    private func withStatement<T>(
        _ sql: String, on db: OpaquePointer, _ operation: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard status == SQLITE_OK, let statement else { throw error(for: db) }
        return try operation(statement)
    }

    private func execute(_ sql: String, on db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(for: db) }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer, on db: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.transient) == SQLITE_OK else {
            throw error(for: db)
        }
    }

    private func error(for db: OpaquePointer?) -> IndexError {
        let code = db.map { sqlite3_errcode($0) }
        if code == SQLITE_FULL {
            return IndexError(message: "Free up device storage and retry to continue indexing.", code: code)
        }
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the search index."
        return IndexError(message: message, code: code)
    }

    private struct IndexError: LocalizedError {
        let message: String
        let code: Int32?
        var errorDescription: String? { message }
    }
}
