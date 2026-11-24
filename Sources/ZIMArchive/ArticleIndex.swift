import Foundation
import SQLite3
import SwiftSoup

public struct ArticleIndex: Sendable {
    public struct Match: Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let title: String
        public let excerpt: String
        public let rank: Double
    }

    private let file: URL
    public static let maximumArchiveSize: Int64 = 1024 * 1024 * 1024
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(archiveURL: URL) {
        file = archiveURL.deletingLastPathComponent().appendingPathComponent("articles-v1.sqlite")
    }

    public var isReady: Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    /// Use a background task. A complete index becomes visible in one rename.
    public func build(
        archiveURL: URL,
        progress: (Double) -> Void = { _ in }
    ) throws {
        guard !isReady else { return }
        let bytes = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(bytes) <= Self.maximumArchiveSize else {
            throw IndexError(message: "Search supports archives up to 1 GB in this build.")
        }
        let archive = try ZIMArchive(fileURL: archiveURL)
        let staging = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: staging) }

        try withDatabase(at: staging, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { db in
            try execute("PRAGMA max_page_count = 131072", on: db)
            try execute(
                "CREATE VIRTUAL TABLE articles USING fts5(path UNINDEXED, title, body, tokenize='unicode61 remove_diacritics 2')",
                on: db
            )
            try execute("BEGIN", on: db)
            try withStatement("INSERT INTO articles(path, title, body) VALUES (?, ?, ?)", on: db) { insert in
                for index in 0..<archive.entryCount {
                    try Task.checkCancellation()
                    if index.isMultiple(of: 128) {
                        progress(Double(index) / Double(max(archive.entryCount, 1)))
                    }
                    guard let article = try archive.article(at: index) else { continue }
                    let html = String(decoding: article.data.prefix(512 * 1024), as: UTF8.self)
                    let body = try SwiftSoup.parse(html).body()?.text() ?? ""
                    try bind(article.path, at: 1, to: insert, on: db)
                    try bind(article.title, at: 2, to: insert, on: db)
                    try bind(body, at: 3, to: insert, on: db)
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw error(for: db) }
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                }
            }
            try execute("COMMIT", on: db)
        }
        if !isReady {
            try FileManager.default.moveItem(at: staging, to: file)
        }
        progress(1)
    }

    public func search(_ query: String) throws -> [Match] {
        let tokens = query.split(whereSeparator: \.isWhitespace).prefix(12)
        guard isReady, !tokens.isEmpty else { return [] }
        let expression = tokens.map { token in
            "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: " AND ")
        return try withDatabase(at: file, flags: SQLITE_OPEN_READONLY) { db in
            try withStatement("""
                SELECT path, title, snippet(articles, 2, '', '', '…', 22), bm25(articles, 0.0, 4.0, 1.0)
                FROM articles WHERE articles MATCH ? ORDER BY 4 LIMIT 30
                """, on: db) { statement in
                try bind(expression, at: 1, to: statement, on: db)
                var matches: [Match] = []
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    matches.append(Match(
                        path: String(cString: sqlite3_column_text(statement, 0)),
                        title: String(cString: sqlite3_column_text(statement, 1)),
                        excerpt: String(cString: sqlite3_column_text(statement, 2)),
                        rank: sqlite3_column_double(statement, 3)
                    ))
                    status = sqlite3_step(statement)
                }
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
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the search index."
        return IndexError(message: message)
    }

    private struct IndexError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
