import Combine
import Foundation

struct ReadingLocation: Hashable, Codable, Sendable {
    let archiveID: UUID
    let path: String
    let pageIndex: Int?
    let fragment: String?

    init(archiveID: UUID, path: String, pageIndex: Int? = nil, fragment: String? = nil) {
        self.archiveID = archiveID
        self.path = path
        self.pageIndex = pageIndex
        self.fragment = fragment
    }

    fileprivate var document: ReadingLocation {
        ReadingLocation(archiveID: archiveID, path: path)
    }

    fileprivate var isValid: Bool {
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !path.contains("\0")
            && (pageIndex.map { $0 >= 0 } ?? true)
            && (fragment.map { !$0.isEmpty && !$0.contains("\0") } ?? true)
            && (pageIndex == nil || fragment == nil)
    }
}

struct ReadingEntry: Codable, Equatable, Identifiable, Sendable {
    let location: ReadingLocation
    let title: String
    let date: Date

    var id: ReadingLocation { location }

    fileprivate var isValid: Bool {
        location.isValid && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
final class ReadingShelf: ObservableObject {
    private struct Snapshot: Codable, Equatable {
        static let historyLimit = 100
        var version = 1
        var bookmarks: [ReadingEntry] = []
        var recent: [ReadingEntry] = []

        var isValid: Bool {
            version == 1
                && recent.count <= Self.historyLimit
                && bookmarks.allSatisfy(\.isValid)
                && recent.allSatisfy(\.isValid)
                && Set(bookmarks.map(\.location)).count == bookmarks.count
                && Set(recent.map(\.location.document)).count == recent.count
        }
    }

    @Published private var snapshot = Snapshot()
    private let readError: Error?
    private let file: URL

    var bookmarks: [ReadingEntry] { snapshot.bookmarks }
    var recent: [ReadingEntry] { snapshot.recent }
    var loadError: String? { readError?.localizedDescription }

    init(file: URL = .applicationSupportDirectory.appendingPathComponent("Reading/reading.json")) {
        self.file = file
        do {
            let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            guard saved.isValid else { throw CocoaError(.fileReadCorruptFile) }
            snapshot = saved
            readError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            readError = nil
        } catch {
            readError = error
        }
    }

    func isBookmarked(_ location: ReadingLocation) -> Bool {
        bookmarks.contains { $0.location == location }
    }

    func toggleBookmark(_ location: ReadingLocation, title: String) throws {
        if isBookmarked(location) {
            try removeBookmark(location)
            return
        }
        var next = snapshot
        next.bookmarks.insert(try makeEntry(location, title: title), at: 0)
        try save(next)
    }

    func recordVisit(_ location: ReadingLocation, title: String) throws {
        let entry = try makeEntry(location, title: title)
        let document = location.document
        var next = snapshot
        next.recent.removeAll { $0.location.document == document }
        next.recent.insert(entry, at: 0)
        if next.recent.count > Snapshot.historyLimit {
            next.recent.removeLast()
        }
        try save(next)
    }

    func removeBookmark(_ location: ReadingLocation) throws {
        var next = snapshot
        next.bookmarks.removeAll { $0.location == location }
        try save(next)
    }

    func clearHistory() throws {
        var next = snapshot
        next.recent.removeAll()
        try save(next)
    }

    private func makeEntry(_ location: ReadingLocation, title: String) throws -> ReadingEntry {
        guard location.isValid else { throw LocationError.invalid }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReadingEntry(location: location, title: title.isEmpty ? location.path : title, date: .now)
    }

    private func save(_ next: Snapshot) throws {
        if let readError { throw readError }
        guard snapshot != next else { return }
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        snapshot = next
    }

    private enum LocationError: LocalizedError {
        case invalid

        var errorDescription: String? { "This reading location could not be saved." }
    }
}
