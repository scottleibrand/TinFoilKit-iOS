import SwiftUI
import ZIMArchive

struct ReadingBookmarkButton: View {
    let location: ReadingLocation
    let title: String
    @EnvironmentObject private var shelf: ReadingShelf
    @State private var error: String?

    var body: some View {
        let saved = shelf.isBookmarked(location)
        Button(saved ? "Remove bookmark" : "Add bookmark", systemImage: saved ? "bookmark.fill" : "bookmark") {
            do { try shelf.toggleBookmark(location, title: title) }
            catch { self.error = error.localizedDescription }
        }
        .alert("Bookmark error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }
}

struct ReadingShelfView: View {
    let library: InstalledLibrary
    @ObservedObject var indexing: LibraryIndexing
    @EnvironmentObject private var shelf: ReadingShelf
    @State private var clearingHistory = false
    @State private var error: String?

    var body: some View {
        List {
            if let loadError = shelf.loadError {
                Text(loadError).foregroundStyle(.secondary)
            }
            Section("Bookmarks") {
                if shelf.bookmarks.isEmpty {
                    Text("Add bookmarks from an open article or PDF.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shelf.bookmarks) { entry in
                    row(for: entry)
                        .accessibilityIdentifier("reading-bookmark-entry")
                        .swipeActions {
                            Button("Remove", systemImage: "bookmark.slash", role: .destructive) {
                                perform { try shelf.removeBookmark(entry.location) }
                            }
                        }
                }
            }
            Section("Recently read") {
                if shelf.recent.isEmpty {
                    Text("No recent articles or documents.").foregroundStyle(.secondary)
                }
                ForEach(shelf.recent) { row(for: $0) }
                if !shelf.recent.isEmpty {
                    Button("Clear recent reading", systemImage: "trash", role: .destructive) {
                        clearingHistory = true
                    }
                }
            }
        }
        .navigationTitle("Reading list")
        .confirmationDialog("Clear recent reading?", isPresented: $clearingHistory, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { perform { try shelf.clearHistory() } }
        }
        .alert("Reading list error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder
    private func row(for entry: ReadingEntry) -> some View {
        if let archive = indexing.archives.first(where: { $0.id == entry.location.archiveID }) {
            NavigationLink {
                ArchiveReaderView(library: library, archive: archive, articlePath: entry.location.path,
                                  initialPageIndex: entry.location.pageIndex, initialFragment: entry.location.fragment)
            } label: {
                ReadingEntryLabel(entry: entry, subtitle: archive.title)
            }
        } else {
            ReadingEntryLabel(entry: entry, subtitle: "Archive unavailable")
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { self.error = error.localizedDescription }
    }
}

private struct ReadingEntryLabel: View {
    let entry: ReadingEntry
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title)
            if let page = entry.location.pageIndex, page < Int.max {
                Text("\(subtitle) · page \(page + 1)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
