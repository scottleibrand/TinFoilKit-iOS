import SwiftUI
import ZIMArchive

enum OfflineReadinessCheckResult: Sendable {
    case passed(String)
    case unavailable(String)
    case failed(String)
}

struct OfflineFunctionalChecksView: View {
    @ObservedObject var indexing: LibraryIndexing
    @AppStorage("askUsesOnDeviceModel") private var useModel = true
    @State private var libraryQuery = ""
    @State private var placeQuery = ""
    @State private var start = ""
    @State private var end = ""
    @State private var request: Request?
    @State private var results: [Check: OfflineReadinessCheckResult] = [:]

    var body: some View {
        Form {
            Section {
                Button("Open a sample reference") { begin(.reference(indexing.archives)) }
                resultRow(.reference)
                Button("Open a sample PDF") { begin(.pdf(indexing.archives)) }
                resultRow(.pdf)
                TextField("Topic in your library", text: $libraryQuery)
                Button("Find citable passages") {
                    begin(.passages(String(libraryQuery.prefix(500)), indexing.archives))
                }
                .disabled(libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                resultRow(.passages)
                Button("Try an on-device answer") { begin(.answer(useModel)) }
                resultRow(.answer)
            } header: {
                Text("Library and Ask")
            } footer: {
                Text("Use a topic you expect to find in your installed library. The answer check uses a built-in sample passage.")
            }
            .disabled(request != nil)

            Section {
                TextField("Address or service name", text: $placeQuery)
                Button("Search installed place data") { begin(.places(String(placeQuery.prefix(200)))) }
                    .disabled(placeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                resultRow(.places)
            } header: {
                Text("Places")
            }
            .disabled(request != nil)

            Section {
                coordinateField("Start coordinates", text: $start)
                coordinateField("Destination coordinates", text: $end)
                Button("Calculate walking and driving routes") {
                    guard let origin, let destination else { return }
                    begin(.routes(origin, destination))
                }
                .disabled(origin == nil || destination == nil)
                resultRow(.walking)
                resultRow(.driving)
            } header: {
                Text("Routes")
            } footer: {
                Text("Paste two coordinates from Map, or enter latitude and longitude separated by a comma. Choose locations in an installed routing region.")
            }
            .disabled(request != nil)

            if request != nil {
                Section {
                    ProgressView("Running offline check")
                    Button("Cancel check", role: .cancel) { request = nil }
                }
            }
        }
        .navigationTitle("Run offline checks")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: request?.id) {
            guard !Task.isCancelled, let request else { return }
            await run(request)
        }
        .onChange(of: libraryQuery) { results.removeValue(forKey: .passages) }
        .onChange(of: placeQuery) { results.removeValue(forKey: .places) }
        .onChange(of: start) { clearRouteResults() }
        .onChange(of: end) { clearRouteResults() }
        .onChange(of: indexing.archives) {
            let libraryChecks: [Check] = [.reference, .pdf, .passages]
            for check in libraryChecks { results.removeValue(forKey: check) }
            if let request, libraryChecks.contains(request.input.firstCheck) {
                self.request = nil
            }
        }
        .onDisappear { request = nil }
    }

    private var origin: MapRoute.Point? { point(start) }
    private var destination: MapRoute.Point? { point(end) }

    private func point(_ text: String) -> MapRoute.Point? {
        MapCoordinateText.parse(text).map { MapRoute.Point(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private func coordinateField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    @ViewBuilder
    private func resultRow(_ check: Check) -> some View {
        if let result = results[check] {
            VStack(alignment: .leading, spacing: 4) {
                switch result {
                case let .passed(detail):
                    Label(check.title + " passed", systemImage: "checkmark.circle")
                    Text(detail).foregroundStyle(.secondary)
                case let .unavailable(detail):
                    Label(check.title + " unavailable", systemImage: "minus.circle")
                    Text(detail).foregroundStyle(.secondary)
                case let .failed(detail):
                    Label(check.title + " did not pass", systemImage: "exclamationmark.circle")
                    Text(detail).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)
        }
    }

    private func begin(_ input: Request.Input) {
        guard request == nil else { return }
        for check in input.checks { results.removeValue(forKey: check) }
        request = Request(input: input)
    }

    private func clearRouteResults() {
        results.removeValue(forKey: .walking)
        results.removeValue(forKey: .driving)
    }

    @MainActor
    private func run(_ current: Request) async {
        defer { if request?.id == current.id { request = nil } }
        let outcome: OfflineReadinessCheckResult
        switch current.input {
        case let .reference(archives):
            outcome = await OfflineReadinessLibraryChecks.reference(in: archives)
        case let .pdf(archives):
            outcome = await OfflineReadinessLibraryChecks.pdf(in: archives)
        case let .passages(query, archives):
            outcome = await OfflineReadinessLibraryChecks.passages(query: query, in: archives)
        case let .answer(enabled):
            outcome = await sampleAnswer(enabled: enabled)
        case let .places(query):
            outcome = await OfflineReadinessRegionalChecks.places(query: query)
        case let .routes(origin, destination):
            let walking = await OfflineReadinessRegionalChecks.route(from: origin, to: destination, mode: .walking)
            guard isCurrent(current) else { return }
            results[.walking] = walking
            let driving = await OfflineReadinessRegionalChecks.route(from: origin, to: destination, mode: .driving)
            if isCurrent(current) { results[.driving] = driving }
            return
        }
        if isCurrent(current) { results[current.input.firstCheck] = outcome }
    }

    private func isCurrent(_ current: Request) -> Bool {
        request?.id == current.id && !Task.isCancelled
    }

    @MainActor
    private func sampleAnswer(enabled: Bool) async -> OfflineReadinessCheckResult {
        guard enabled else { return .unavailable("On-device answers are turned off in Ask.") }
        guard LibraryAnswer.isAvailable else { return .unavailable("The on-device model is unavailable.") }
        do {
            let answer = try await LibraryAnswer.stream(
                question: "What color is the binder for the sample check-in card?",
                passages: [("Sample check-in card", "The sample check-in card is stored in a blue binder.")],
                onUpdate: { _ in }
            )
            guard let answer, answer.range(of: #"\bblue\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  AnswerCitations.indices(in: answer, sourceCount: 1) == [0] else {
                return .failed("The model did not return the expected answer with its sample citation.")
            }
            return .passed("The model answered from the sample passage and cited it.")
        } catch {
            return .failed("The on-device model could not finish the sample answer.")
        }
    }

    private enum Check: Hashable {
        case reference, pdf, passages, answer, places, walking, driving

        var title: String {
            switch self {
            case .reference: "Reference"
            case .pdf: "PDF"
            case .passages: "Passage search"
            case .answer: "On-device answer"
            case .places: "Place search"
            case .walking: "Walking route"
            case .driving: "Driving route"
            }
        }
    }

    private struct Request: Identifiable {
        let id = UUID()
        let input: Input

        enum Input {
            case reference([InstalledArchive])
            case pdf([InstalledArchive])
            case passages(String, [InstalledArchive])
            case answer(Bool)
            case places(String)
            case routes(MapRoute.Point, MapRoute.Point)

            var checks: [Check] {
                if case .routes = self { return [.walking, .driving] }
                return [firstCheck]
            }

            var firstCheck: Check {
                switch self {
                case .reference: .reference
                case .pdf: .pdf
                case .passages: .passages
                case .answer: .answer
                case .places: .places
                case .routes: .walking
                }
            }
        }
    }
}
