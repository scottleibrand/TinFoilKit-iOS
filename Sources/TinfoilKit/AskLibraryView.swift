import SwiftUI
import ZIMArchive

struct AskLibraryView: View {
    let library: InstalledLibrary
    @ObservedObject var indexing: LibraryIndexing
    @AppStorage("askUsesOnDeviceModel") private var useModel = true
    @FocusState private var questionFocused: Bool
    @FocusState private var serviceAreaFocused: Bool
    @State private var question = ""
    @State private var waterServiceArea = ""
    @State private var request: Request?
    @State private var searchedQuestion: String?
    @State private var sources: [SummarySource] = []
    @State private var answer = ""
    @State private var progress: String?
    @State private var message: String?
    @State private var unreadableArchives = 0
    @State private var savedAnswers: [OnlineAskSavedAnswer] = []
    @State private var savedWebSources: [OnlineAskSavedSource] = []
    @State private var showingSavedSources = false
    @State private var showingOfflineChat = false
    @State private var evidence: [AskEvidence] = []
    @State private var cited: AskEvidence?
    @State private var onlineSheet: OnlineSheet?
    @State private var fallbackQuestion: String?

    private var currentQuestion: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var modelEnabled: Bool { useModel && LibraryAnswer.isAvailable }
    private var waterContext: WaterOutageContext? {
        WaterOutageContext(question: currentQuestion, serviceArea: waterServiceArea)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Question or search terms", text: $question, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("ask-question")
                        .focused($questionFocused)
                        .disabled(request != nil)
                    if let context = WaterOutageContext(question: currentQuestion), context.serviceArea == nil {
                        TextField("Water utility or service area", text: $waterServiceArea)
                            .textInputAutocapitalization(.words)
                            .focused($serviceAreaFocused)
                            .disabled(request != nil)
                    }
                    HStack {
                        Button("Ask", systemImage: "sparkles") { start(.ask) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("ask-submit")
                        Button("Search", systemImage: "magnifyingglass") { start(.search) }
                            .buttonStyle(.bordered)
                    }
                    .disabled(request != nil || currentQuestion.isEmpty)
                    if let progress {
                        ProgressView(progress)
                        Button("Stop", role: .cancel) { stop() }
                    }
                } footer: {
                    if indexing.archives.isEmpty {
                        Text("Search checks saved web sources, saved answers, and installed content packs.")
                    } else if indexing.hasPendingIndexes {
                        if let index = indexing.progress {
                            Text("Indexing \(index.title) · \(index.fraction.formatted(.percent.precision(.fractionLength(0))))")
                        } else {
                            Text("Preparing library search.")
                        }
                    } else if !modelEnabled {
                        Text("Ask searches the saved library when the model is off.")
                    }
                }
                results
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Ask")
            .toolbar {
                if questionFocused || serviceAreaFocused {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Done") {
                            questionFocused = false
                            serviceAreaFocused = false
                        }
                            .accessibilityIdentifier("ask-dismiss-keyboard")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Offline Chat", systemImage: "bubble.left.and.bubble.right") {
                            questionFocused = false
                            serviceAreaFocused = false
                            showingOfflineChat = true
                        }
                        Button("Online providers", systemImage: "key") { onlineSheet = OnlineSheet(question: nil) }
                        Button("Saved web sources", systemImage: "doc.text") { showingSavedSources = true }
                        if LibraryAnswer.isAvailable {
                            Toggle("Use on-device model in Ask", isOn: $useModel)
                        }
                    } label: {
                        Label("Ask options", systemImage: "ellipsis.circle")
                    }
                    .disabled(request != nil)
                }
            }
            .task(id: request?.id) {
                if let request { await run(request) }
            }
            .sheet(item: $onlineSheet) { sheet in
                OnlineAskView(question: sheet.question) {
                    if let question = sheet.question {
                        Task { await refreshSavedContent(for: question) }
                    }
                }
            }
            .sheet(isPresented: $showingSavedSources) {
                SavedWebSourcesView {
                    Task { await refreshSavedContent(for: currentQuestion) }
                }
            }
            .sheet(isPresented: $showingOfflineChat) { OfflineChatView() }
            .sheet(item: $cited) { reference in
                NavigationStack {
                    evidenceDestination(reference)
                        .toolbar { Button("Done") { cited = nil } }
                }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if let message {
            Section { Text(message) }
        }
        if !answer.isEmpty {
            Section("Answer") {
                Text(AnswerCitations.linkedText(answer, sourceCount: min(6, evidence.count)))
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let index = AnswerCitations.sourceIndex(from: url, sourceCount: min(6, evidence.count)) else {
                            return .discarded
                        }
                        cited = evidence[index]
                        return .handled
                    })
            }
        }
        if request == nil, let fallbackQuestion, fallbackQuestion == currentQuestion {
            Section {
                Button("Ask online", systemImage: "globe") {
                    questionFocused = false
                    onlineSheet = OnlineSheet(question: fallbackQuestion)
                }
            }
        }
        if !savedAnswers.isEmpty {
            Section("Saved online answers") {
                ForEach(savedAnswers) { entry in
                    NavigationLink {
                        OnlineAskSavedAnswerView(entry: entry)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(entry.question)
                            Text("\(entry.provider.title) · \(entry.savedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if !evidence.isEmpty {
            Section("Matching passages") {
                if request == nil, answer.isEmpty, modelEnabled, searchedQuestion == currentQuestion, waterContext == nil {
                    Button("Answer from these passages", systemImage: "sparkles") { start(.answerFromPassages) }
                }
                ForEach(Array(evidence.enumerated()), id: \.element.id) { index, reference in
                    NavigationLink {
                        evidenceDestination(reference)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("[\(index + 1)] \(reference.title)").font(.headline)
                            Text(reference.excerpt).font(.subheadline)
                            Text(reference.origin).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if unreadableArchives > 0 {
            Section { Text("Some installed archives could not be searched.").foregroundStyle(.secondary) }
        }
        if !indexing.errors.isEmpty {
            Section {
                Button("Retry search indexing") { indexing.retryFailedIndexes() }
            }
        }
    }

    private func start(_ mode: Mode) {
        let question = currentQuestion
        guard !question.isEmpty, request == nil else { return }
        questionFocused = false
        serviceAreaFocused = false
        if mode != .answerFromPassages {
            sources = []
            savedAnswers = []
            savedWebSources = []
            evidence = []
            searchedQuestion = nil
            unreadableArchives = 0
        }
        answer = ""
        fallbackQuestion = nil
        message = nil
        progress = mode == .answerFromPassages ? "Reading the matching passages" : "Searching the library"
        request = Request(question: question, mode: mode, useModel: modelEnabled, waterContext: waterContext)
    }

    private func stop() {
        request = nil
        progress = nil
        answer = ""
        fallbackQuestion = nil
        message = "Stopped."
    }

    private func run(_ request: Request) async {
        defer {
            if self.request?.id == request.id {
                self.request = nil
                progress = nil
            }
        }
        do {
            if request.mode != .answerFromPassages {
                await refreshSavedContent(for: request.question, waterContext: request.waterContext)
                var found = try await LibraryPassages.search(
                    question: request.question, waterContext: request.waterContext, archives: indexing.archives, library: library
                )
                let retryUntil = ContinuousClock.now + .seconds(12)
                while found.sources.isEmpty, savedAnswers.isEmpty, savedWebSources.isEmpty,
                      indexing.hasPendingIndexes, ContinuousClock.now < retryUntil {
                    try Task.checkCancellation()
                    guard self.request?.id == request.id else { return }
                    progress = "Waiting for matching articles to finish indexing"
                    try await Task.sleep(for: .seconds(3))
                    found = try await LibraryPassages.search(
                        question: request.question, waterContext: request.waterContext, archives: indexing.archives, library: library
                    )
                }
                if found.sources.isEmpty, savedAnswers.isEmpty, savedWebSources.isEmpty, !indexing.hasPendingIndexes,
                   request.mode == .ask, request.useModel, request.waterContext == nil {
                    progress = "Checking related search terms"
                    let queries = (try? await LibraryAnswer.suggestedQueries(for: request.question)) ?? []
                    try Task.checkCancellation()
                    if !queries.isEmpty {
                        found = try await LibraryPassages.search(
                            question: request.question, suggestedQueries: queries, archives: indexing.archives,
                            library: library
                        )
                    }
                }
                try Task.checkCancellation()
                guard self.request?.id == request.id else { return }
                sources = found.sources
                searchedQuestion = request.question
                unreadableArchives = found.unreadableArchives
                updateEvidence(for: request.question, waterContext: request.waterContext)
            }
            if let context = request.waterContext, request.mode != .search {
                explainWaterOutage(context, question: request.question)
                return
            }
            guard !evidence.isEmpty else {
                message = indexing.hasPendingIndexes
                    ? "No matches in searchable content yet. Indexing is still running."
                    : "No matching passages. Try other terms."
                fallbackQuestion = request.question
                return
            }
            if request.mode != .search, request.useModel {
                progress = "Reading the matching passages"
                let answer = try await LibraryAnswer.stream(
                    question: request.question,
                    passages: evidence.prefix(6).map { ($0.title, $0.excerpt) }
                ) { partial in
                    if self.request?.id == request.id { self.answer = partial }
                }
                try Task.checkCancellation()
                guard self.request?.id == request.id else { return }
                self.answer = answer ?? ""
                if answer == nil {
                    message = "The matching passages did not support an answer."
                    fallbackQuestion = request.question
                }
            } else if request.mode == .ask {
                fallbackQuestion = request.question
            }
        } catch is CancellationError {
            if self.request?.id == request.id { self.answer = "" }
        } catch {
            guard self.request?.id == request.id else { return }
            answer = ""
            message = sources.isEmpty ? "The library search could not finish." :
                "The on-device answer could not finish. The matching passages are below."
            fallbackQuestion = request.question
        }
    }

    private func explainWaterOutage(_ context: WaterOutageContext, question: String) {
        guard let area = context.serviceArea else {
            message = "Enter your water utility or service area to look for a local estimate."
            fallbackQuestion = question
            return
        }
        for (index, reference) in evidence.prefix(6).enumerated() where reference.isReference {
            if let quote = context.supportedQuote(in: reference.excerpt, title: reference.title) {
                answer = "A saved reference for \(area) says “\(quote)” [\(index + 1)]"
                message = "Check the source for the facilities and outage conditions it covers."
                return
            }
        }
        message = "The saved references don’t establish how long water service in \(area) would continue during a power outage."
        fallbackQuestion = question
    }

    private func refreshSavedContent(for question: String, waterContext requested: WaterOutageContext? = nil) async {
        let context = requested ?? waterContext
        let answers = (try? await OnlineAskCache.shared.search(question)) ?? []
        let webSources = (try? await OnlineAskCache.shared.searchWebSources(context?.searchQuestion(question) ?? question)) ?? []
        guard !Task.isCancelled, currentQuestion == question else { return }
        savedAnswers = answers
        savedWebSources = webSources
        if request == nil, answer.isEmpty, searchedQuestion == question {
            updateEvidence(for: question, waterContext: context)
            if context == nil, !evidence.isEmpty { message = nil }
        }
    }

    private func updateEvidence(for question: String, waterContext: WaterOutageContext?) {
        let matches = AskEvidence.combine(sources, savedAnswers: savedAnswers, savedWebSources: savedWebSources,
                                          question: waterContext?.searchQuestion(question) ?? question)
        guard let waterContext else { evidence = matches; return }
        let scoped = matches.filter { $0.isReference && waterContext.relates($0.excerpt, title: $0.title) }
        let ids = Set(scoped.map(\.id))
        evidence = scoped + matches.filter { !ids.contains($0.id) }
    }

    @ViewBuilder
    private func evidenceDestination(_ evidence: AskEvidence) -> some View {
        switch evidence {
        case let .archive(source):
            ArchiveReaderView(library: library, archive: source.archive, articlePath: source.match.path)
        case let .answer(entry, _):
            OnlineAskSavedAnswerView(entry: entry)
        case let .web(source, _):
            OnlineAskSourceView(source: source)
        }
    }

    private enum Mode: Equatable {
        case search, ask, answerFromPassages
    }

    private struct Request {
        let id = UUID()
        let question: String
        let mode: Mode
        let useModel: Bool
        let waterContext: WaterOutageContext?
    }

    private struct OnlineSheet: Identifiable {
        let id = UUID()
        let question: String?
    }
}

private enum AskEvidence: Identifiable {
    case archive(SummarySource)
    case answer(OnlineAskSavedAnswer, String)
    case web(OnlineAskSavedSource, String)

    var isReference: Bool {
        switch self {
        case .archive: true
        case .web(let source, _): source.text != nil
        case .answer: false
        }
    }

    var id: String {
        switch self {
        case let .archive(source): source.id
        case let .answer(entry, _): "saved-answer-\(entry.id)"
        case let .web(source, _): "saved-source-\(source.id.absoluteString)"
        }
    }

    var title: String {
        switch self {
        case let .archive(source): source.match.title
        case let .answer(entry, _): entry.question
        case let .web(source, _): source.citation.title
        }
    }

    var excerpt: String {
        switch self {
        case let .archive(source): source.match.excerpt
        case let .answer(_, text), let .web(_, text): text
        }
    }

    var origin: String {
        switch self {
        case let .archive(source): source.archive.title
        case let .answer(entry, _):
            "Saved \(entry.provider.title) answer · \(entry.savedAt.formatted(date: .abbreviated, time: .omitted))"
        case let .web(source, _): source.resolvedURL?.host ?? source.citation.url.host ?? "Saved web source"
        }
    }

    static func combine(_ local: [SummarySource], savedAnswers: [OnlineAskSavedAnswer],
                        savedWebSources: [OnlineAskSavedSource], question: String) -> [Self] {
        let keywords = OnlineAskCache.words(question)
        var seen: Set<URL> = []
        var cached: [Self] = savedWebSources.compactMap { source in
            guard let text = source.text, let fragment = bestFragment(text, keywords: keywords),
                  seen.insert(source.id).inserted else { return nil }
            return .web(source, fragment.text)
        }
        for entry in savedAnswers {
            let candidates = entry.sources.compactMap { source -> (OnlineAskSavedSource, Fragment)? in
                guard let excerpt = source.text ?? source.citation.excerpt,
                      let fragment = bestFragment(excerpt, keywords: keywords), fragment.score > 0 else { return nil }
                return (source, fragment)
            }.sorted { $0.1.score > $1.1.score }
            if let answer = bestFragment(entry.answer, keywords: keywords) {
                cached.append(.answer(entry, answer.text))
            }
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
