import SwiftUI
import ZIMArchive

struct AskLibraryView: View {
    let library: InstalledLibrary
    @ObservedObject var indexing: LibraryIndexing
    @ObservedObject var household: HouseholdStore
    let openMap: (MapOpenRequest?) -> Void
    @AppStorage("askUsesOnDeviceModel") private var useModel = true
    @State private var includeHouseholdNotes = false
    @FocusState private var questionFocused: Bool
    @FocusState private var serviceAreaFocused: Bool
    @State private var question = ""
    @State private var waterServiceArea = ""
    @State private var request: Request?
    @State private var searchedQuestion: String?
    @State private var sources: [SummarySource] = []
    @State private var answer = ""
    @State private var quotedQuestion: String?
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
    @State private var nearbyResult: NearbyAnswer?
    @State private var needsMapSetup = false
    @State private var homeRoutes: [HomeDestination] = []

    private var currentQuestion: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var modelEnabled: Bool { useModel && LibraryAnswer.isAvailable }
    private var householdNotes: String {
        household.snapshot.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var waterContext: WaterOutageContext? {
        WaterOutageContext(question: currentQuestion, serviceArea: waterServiceArea)
    }
    private var quoteIndices: [Int] {
        guard quotedQuestion == currentQuestion else { return [] }
        return LibraryPassages.quoteIndices(for: currentQuestion, excerpts: evidence.map(\.excerpt))
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
                    if modelEnabled, waterContext == nil, !householdNotes.isEmpty,
                       OfflineAskIntent.parse(currentQuestion).canUseHouseholdNotes {
                        Toggle("Include household notes in the on-device answer", isOn: $includeHouseholdNotes)
                            .disabled(request != nil)
                    }
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
                        Text("Ask can highlight quotes from saved sources without the on-device model.")
                    }
                }
                results
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: question) {
                homeRoutes = []
                nearbyResult = nil
                includeHouseholdNotes = false
                quotedQuestion = nil
            }
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
        if needsMapSetup {
            Section {
                Button("Open Map", systemImage: "map") { openMap(nil) }
            }
        }
        if let nearbyResult {
            nearbyAnswer(nearbyResult)
        }
        if !homeRoutes.isEmpty {
            Section("Directions from Home") {
                ForEach(homeRoutes) { destination in
                    ForEach(destination.modes) { mode in
                        Button {
                            openMap(MapOpenRequest(place: destination.place,
                                                   route: .init(origin: destination.origin, mode: mode)))
                        } label: {
                            VStack(alignment: .leading) {
                                Label("\(mode.title) to \(destination.place.name)",
                                      systemImage: mode == .walking ? "figure.walk" : "car")
                                Text(destination.place.kind).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
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
        let quotes = quoteIndices
        if !quotes.isEmpty {
            Section("Quotes from saved sources") {
                ForEach(quotes, id: \.self) { index in
                    let reference = evidence[index]
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: reference.excerpt).textSelection(.enabled)
                        Button("[\(index + 1)] \(reference.title)", systemImage: "book") { cited = reference }
                            .accessibilityIdentifier("ask-quote-\(index + 1)")
                        Text(reference.origin).font(.caption).foregroundStyle(.secondary)
                    }
                }
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

    private func nearbyAnswer(_ result: NearbyAnswer) -> some View {
        let match = result.nearby.match
        let place = match.place
        let metadata = match.region.metadata
        let destinationPlace = MapPlace(id: match.id, name: place.name, kind: place.categoryLabel,
                                        latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
        let distance = Measurement(value: result.nearby.distanceMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        return Section {
            VStack(alignment: .leading, spacing: 5) {
                Text(place.name).font(.headline)
                if !place.address.isEmpty { Text(place.address) }
                Text("\(distance) straight-line distance from Home")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(result.routeModes) { mode in
                Button(mode == .walking ? "Walk from Home" : "Drive from Home",
                       systemImage: mode == .walking ? "figure.walk" : "car") {
                    openMap(MapOpenRequest(place: destinationPlace, route: .init(origin: result.routeOrigin, mode: mode)))
                }
            }
            Button("Show on map", systemImage: "map") {
                openMap(MapOpenRequest(place: destinationPlace))
            }
            if let destination = MapCoordinateText.googleMapsURL(place.coordinate) {
                Link(destination: destination) {
                    Label("Open in Google Maps", systemImage: "arrow.up.right.square")
                }
            }
            Link([metadata.region, metadata.dataVersion].compactMap { $0 }.joined(separator: " · "),
                 destination: metadata.source)
            Link(metadata.attribution, destination: metadata.licenseURL)
                .font(.footnote)
        } header: {
            Text("Nearest in installed place data")
        } footer: {
            Text("Check current hours and access before traveling.")
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
        quotedQuestion = nil
        fallbackQuestion = nil
        message = nil
        nearbyResult = nil
        needsMapSetup = false
        homeRoutes = []
        let onDevice = modelEnabled
        let wantsNotes = includeHouseholdNotes
        if mode != .search { includeHouseholdNotes = false }
        let intent = mode == .ask ? OfflineAskIntent.parse(question) : .reference
        if case let .destination(destination) = intent, prepareKnownRoute(destination) { return }

        switch (mode, intent) {
        case (.answerFromPassages, _): progress = "Reading the matching passages"
        case (_, .reference): progress = "Searching the library"
        default: progress = "Searching installed place data"
        }
        let context = waterContext
        let notes: String? = if mode != .search, intent.canUseHouseholdNotes, context == nil,
                               onDevice, wantsNotes, !householdNotes.isEmpty {
            String(householdNotes.prefix(LibraryAnswerPrompt.maximumHouseholdNotesLength))
        } else {
            nil
        }
        request = Request(question: question, mode: mode, useModel: onDevice, waterContext: context,
                          intent: intent, householdNotes: notes)
    }

    private func prepareKnownRoute(_ question: HomeRouteQuestion) -> Bool {
        let snapshot = household.snapshot
        let matches = question.matchingPins(in: snapshot.pins.map(\.name))
        guard matches.count <= 1 else {
            message = "More than one saved pin has that name. Rename one in Household to choose a unique destination."
            return true
        }
        let destination: MapPlace
        if let index = matches.first {
            let pin = snapshot.pins[index]
            destination = MapPlace(id: pin.id.uuidString, name: pin.name, kind: "Saved pin",
                                   latitude: pin.latitude, longitude: pin.longitude)
        } else if let point = MapCoordinateText.parse(question.rawDestination) {
            let coordinates = MapCoordinateText.decimal(point)
            destination = MapPlace(id: coordinates, name: coordinates, kind: "Coordinates",
                                   latitude: point.latitude, longitude: point.longitude)
        } else {
            return false
        }
        guard let home = snapshot.home else {
            showMissingHome()
            return true
        }
        homeRoutes = [HomeDestination(place: destination, origin: home, modes: question.mode.travelModes)]
        return true
    }

    private func stop() {
        request = nil
        progress = nil
        answer = ""
        quotedQuestion = nil
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
        if case let .destination(destinationRoute) = request.intent {
            if await answerDestinationRoute(destinationRoute, request: request) { return }
            guard self.request?.id == request.id, !Task.isCancelled else { return }
            progress = "Searching the library"
        }
        if case let .service(service, mode) = request.intent,
           let category = RegionalPlaceIndex.Category(rawValue: service.rawValue) {
            await answerNearby(category, routeModes: mode?.travelModes ?? [], request: request)
            return
        }
        do {
            if request.mode != .answerFromPassages {
                await refreshSavedContent(for: request.question, waterContext: request.waterContext)
                let referenceQuery = request.waterContext?.searchQuestion(request.question) ?? request.question
                let hasSavedReferenceText = !AskEvidence.combine([], savedAnswers: savedAnswers,
                    savedWebSources: savedWebSources, question: referenceQuery).isEmpty
                var found = try await LibraryPassages.search(
                    question: request.question, waterContext: request.waterContext, archives: indexing.archives, library: library
                )
                let retryUntil = ContinuousClock.now + .seconds(12)
                while found.sources.isEmpty, !hasSavedReferenceText,
                      indexing.hasPendingIndexes, ContinuousClock.now < retryUntil {
                    try Task.checkCancellation()
                    guard self.request?.id == request.id else { return }
                    progress = "Waiting for matching articles to finish indexing"
                    try await Task.sleep(for: .seconds(3))
                    found = try await LibraryPassages.search(
                        question: request.question, waterContext: request.waterContext, archives: indexing.archives, library: library
                    )
                }
                if found.sources.isEmpty, !hasSavedReferenceText, !indexing.hasPendingIndexes,
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
                if !savedAnswers.isEmpty {
                    message = "Found saved answers, but no matching reference passages."
                    fallbackQuestion = request.question
                    return
                }
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
                    passages: evidence.prefix(6).map { ($0.title, $0.excerpt) },
                    householdNotes: request.householdNotes
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
                quotedQuestion = request.question
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

    /// Returns false for ambiguous wording that did not resolve to a local destination.
    private func answerDestinationRoute(_ question: HomeRouteQuestion, request: Request) async -> Bool {
        guard self.request?.id == request.id, !Task.isCancelled else { return true }
        guard let home = household.snapshot.home else {
            if question.allowsLibraryFallback { return false }
            showMissingHome()
            return true
        }
        do {
            let matches = try await RegionalPlaceSearch.destinationsInstalled(
                matching: question, from: home, storage: RegionalPlaceStorage()
            )
            guard self.request?.id == request.id, !Task.isCancelled else { return true }
            guard let matches else {
                if question.allowsLibraryFallback { return false }
                message = "Import regional place data from Map to look up this destination offline."
                needsMapSetup = true
                return true
            }
            guard !matches.isEmpty else {
                if question.allowsLibraryFallback { return false }
                message = "No exact match in installed place data. Check the name or address, or search in Map."
                needsMapSetup = true
                return true
            }
            homeRoutes = matches.map { match in
                let place = match.place
                let region = match.region.metadata.region
                let name = question.isStreetAddress ? place.address : place.name
                let context = question.isStreetAddress ? place.name : place.address
                let detail: String
                if !context.isEmpty, name != context {
                    detail = "\(context) · \(region)"
                } else if matches.count > 1 {
                    detail = "\(MapCoordinateText.decimal(place.coordinate)) · \(region)"
                } else {
                    detail = region
                }
                let destination = MapPlace(id: match.id, name: name, kind: detail,
                                           latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
                return HomeDestination(place: destination, origin: home, modes: question.mode.travelModes)
            }
        } catch {
            guard self.request?.id == request.id, !Task.isCancelled else { return true }
            if question.allowsLibraryFallback { return false }
            message = "The installed place data could not be searched."
            needsMapSetup = true
        }
        return true
    }

    private func showMissingHome() {
        message = "Press and hold your home location in Map and choose Set as home."
        needsMapSetup = true
    }

    private func answerNearby(_ category: RegionalPlaceIndex.Category, routeModes: [MapTravelMode], request: Request) async {
        guard self.request?.id == request.id, !Task.isCancelled else { return }
        guard let home = household.snapshot.home else {
            showMissingHome()
            return
        }
        do {
            let result = try await RegionalPlaceSearch.nearestInstalled(category, from: home, storage: RegionalPlaceStorage())
            guard self.request?.id == request.id, !Task.isCancelled else { return }
            switch result {
            case .noPlaceData:
                message = "Import regional place data from Map to look up nearby services offline."
                needsMapSetup = true
            case .noMatch:
                message = "No matching service near Home was found in the installed place data."
                fallbackQuestion = request.question
            case .match(let nearby):
                nearbyResult = NearbyAnswer(nearby: nearby, routeOrigin: home, routeModes: routeModes)
            }
        } catch {
            guard self.request?.id == request.id, !Task.isCancelled else { return }
            message = "The installed place data could not be searched."
            needsMapSetup = true
        }
    }

    private func explainWaterOutage(_ context: WaterOutageContext, question: String) {
        guard let area = context.serviceArea else {
            message = "Enter your water utility or service area to look for a local estimate."
            fallbackQuestion = question
            return
        }
        for (index, reference) in evidence.prefix(6).enumerated() {
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
        let scoped = matches.filter { waterContext.relates($0.excerpt, title: $0.title) }
        let ids = Set(scoped.map(\.id))
        evidence = scoped + matches.filter { !ids.contains($0.id) }
    }

    @ViewBuilder
    private func evidenceDestination(_ evidence: AskEvidence) -> some View {
        switch evidence {
        case let .archive(source):
            ArchiveReaderView(library: library, archive: source.archive, articlePath: source.match.path)
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
        let intent: OfflineAskIntent
        let householdNotes: String?
    }

    private struct NearbyAnswer {
        let nearby: RegionalPlaceSearch.Nearby
        let routeOrigin: HouseholdPlace
        let routeModes: [MapTravelMode]
    }

    private struct HomeDestination: Identifiable {
        let place: MapPlace
        let origin: HouseholdPlace
        let modes: [MapTravelMode]

        var id: String { place.id }
    }

    private struct OnlineSheet: Identifiable {
        let id = UUID()
        let question: String?
    }
}

private extension HomeRouteQuestion.Mode {
    var travelModes: [MapTravelMode] {
        switch self {
        case .walking: [.walking]
        case .driving: [.driving]
        case .choose: MapTravelMode.allCases
        }
    }
}
