import SwiftUI
import ZIMArchive

struct ArticleSummaryView: View {
    let library: InstalledLibrary
    let question: String
    let sources: [SummarySource]
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var answer = ""
    @State private var working = true

    var body: some View {
        NavigationStack {
            List {
                Section("On-device summary") {
                    if working {
                        ProgressView("Reading the matching passages")
                    }
                    if !answer.isEmpty {
                        LibraryAnswerText(answer: answer, sources: sources, library: library)
                    } else if let message {
                        Text(message)
                    }
                }
                Section("Matching passages") {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        LibraryPassageRow(source: source, number: index + 1, library: library)
                    }
                }
            }
            .navigationTitle("Article summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { await summarize() }
        }
    }

    static var isAvailable: Bool { LibraryAnswer.isAvailable }

    private func summarize() async {
        defer { working = false }
        guard Self.isAvailable else {
            message = "The on-device model is unavailable. You can still read the matching passages."
            return
        }
        do {
            answer = try await LibraryAnswer.stream(question: question, sources: sources) { answer = $0 } ?? ""
            if answer.isEmpty { message = "The matching passages did not support an answer." }
        } catch is CancellationError {
            answer = ""
        } catch {
            answer = ""
            message = "The on-device model could not make a summary. The matching passages are below."
        }
    }
}

struct LibraryAnswerText: View {
    let answer: String
    let sources: [SummarySource]
    let library: InstalledLibrary
    @State private var source: SummarySource?

    var body: some View {
        Text(AnswerCitations.linkedText(answer, sourceCount: sources.count))
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard let index = AnswerCitations.sourceIndex(from: url, sourceCount: sources.count) else {
                    return .discarded
                }
                source = sources[index]
                return .handled
            })
            .sheet(item: $source) { source in
                NavigationStack {
                    CitedArticleView(library: library, source: source)
                }
            }
    }
}

private struct CitedArticleView: View {
    let library: InstalledLibrary
    let source: SummarySource
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ArchiveReaderView(library: library, archive: source.archive, articlePath: source.match.path)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
    }
}

struct LibraryPassageRow: View {
    let source: SummarySource
    let number: Int
    let library: InstalledLibrary

    var body: some View {
        NavigationLink {
            ArchiveReaderView(library: library, archive: source.archive, articlePath: source.match.path)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("[\(number)] \(source.match.title)").font(.headline)
                Text(source.match.excerpt).font(.subheadline)
                Text(source.archive.title).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
