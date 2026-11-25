import SwiftUI

struct DeferredAskDraft: Identifiable {
    let id = UUID()
    let question: String
    let provider: OnlineAskProvider
}

struct DeferredAskConfirmationView: View {
    let draft: DeferredAskDraft
    @EnvironmentObject private var deferredAsk: DeferredAskController
    @Environment(\.dismiss) private var dismiss
    @State private var allowMetered = false
    @State private var isQueueing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Request") {
                    LabeledContent("Provider", value: draft.provider.title)
                    Text(verbatim: draft.question).textSelection(.enabled)
                }
                Section {
                    Toggle("Allow metered connections", isOn: $allowMetered)
                        .disabled(isQueueing)
                } header: {
                    Text("Network")
                } footer: {
                    Text("With this off, the question waits for an unmetered connection. Turn it on to allow cellular or Low Data Mode.")
                }
                Section {
                    Text("Tinfoil Kit keeps this question on this device until it can send while the app is open. The selected provider receives the question and may charge for processing and web search. Provider rate limits may require a retry.")
                    Text("The answer and citation details are saved on this device. Open original source links when connected.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.circle") }
                }
                Section {
                    if isQueueing {
                        ProgressView("Saving to the queue")
                    } else {
                        Button("Queue question", systemImage: "clock") {
                            Task { await enqueue() }
                        }
                    }
                }
            }
            .navigationTitle("Confirm deferred question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isQueueing)
                }
            }
        }
        .interactiveDismissDisabled(isQueueing)
    }

    private func enqueue() async {
        guard !isQueueing else { return }
        isQueueing = true
        error = nil
        defer { isQueueing = false }
        do {
            try await deferredAsk.enqueue(question: draft.question, provider: draft.provider, allowMetered: allowMetered)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DeferredAskQueueSection: View {
    @EnvironmentObject private var deferredAsk: DeferredAskController

    var body: some View {
        Section {
            if deferredAsk.jobs.isEmpty {
                Text("No deferred questions").foregroundStyle(.secondary)
            }
            ForEach(deferredAsk.jobs.sorted { $0.createdAt > $1.createdAt }) { job in
                NavigationLink {
                    DeferredAskJobView(id: job.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: job.question).lineLimit(2)
                        Text("\(job.provider.title) · \(job.displayState)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = deferredAsk.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
        } header: {
            Text("Deferred questions")
        } footer: {
            Text("Queued questions send while Tinfoil Kit is open and an allowed connection is available.")
        }
    }
}

private struct DeferredAskJobView: View {
    let id: UUID
    @EnvironmentObject private var deferredAsk: DeferredAskController
    @Environment(\.dismiss) private var dismiss
    @State private var pendingAction: Action?
    @State private var isUpdating = false

    private enum Action {
        case cancel
        case retry
        case remove

        var title: String {
            switch self {
            case .cancel: "Cancel this request?"
            case .retry: "Retry this question?"
            case .remove: "Remove this queue entry?"
            }
        }

        var button: String {
            switch self {
            case .cancel: "Cancel request"
            case .retry: "Retry question"
            case .remove: "Remove queue entry"
            }
        }

        var role: ButtonRole? {
            switch self {
            case .cancel, .remove: .destructive
            case .retry: nil
            }
        }
    }

    private var job: DeferredAskJob? {
        deferredAsk.jobs.first { $0.id == id }
    }

    var body: some View {
        List {
            if let job {
                Section("Question") {
                    Text(verbatim: job.question).textSelection(.enabled)
                }
                Section("Request status") {
                    LabeledContent("Provider", value: job.provider.title)
                    LabeledContent("Status", value: job.displayState)
                    LabeledContent("Added to queue", value: job.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Network", value: job.allowMetered ? "Metered allowed" : "Unmetered only")
                    LabeledContent("Attempts", value: job.attempts.formatted())
                    if let next = job.nextAttemptAt {
                        LabeledContent("Earliest next attempt", value: next.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let note = job.note {
                        Text(note).foregroundStyle(.secondary)
                    }
                }
                jobActions(job)
            } else {
                Text("This queue entry is unavailable.").foregroundStyle(.secondary)
            }
            if let error = deferredAsk.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Deferred question")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(pendingAction?.title ?? "", isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
        ), titleVisibility: .visible, presenting: pendingAction) { action in
            Button(action.button, role: action.role) {
                Task { await apply(action) }
            }
        } message: { action in
            Text(actionMessage(action))
        }
    }

    private func jobActions(_ job: DeferredAskJob) -> some View {
        Section {
            switch job.state {
            case .queued, .running:
                Button("Cancel request", role: .destructive) { pendingAction = .cancel }
            case .retryRequired:
                Button("Review retry") { pendingAction = .retry }
                Button("Remove queue entry", role: .destructive) { pendingAction = .remove }
            case .saved:
                NavigationLink("Read saved answer") { DeferredAskSavedAnswerView(id: id) }
                Button("Remove queue entry", role: .destructive) { pendingAction = .remove }
            case .cancelled:
                Button("Remove queue entry", role: .destructive) { pendingAction = .remove }
            }
        }
        .disabled(isUpdating)
    }

    private func actionMessage(_ action: Action) -> String {
        switch action {
        case .cancel:
            "If sending has started, the provider may already have received the question and may charge for it."
        case .retry:
            "Retry sends the same question to \(job?.provider.title ?? "the original provider"). An earlier attempt may already have reached the provider. Provider charges may apply again."
        case .remove:
            job?.state == .saved ? "The saved answer remains available in Ask." : "The question will be removed from this device’s queue."
        }
    }

    private func apply(_ action: Action) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        switch action {
        case .cancel:
            await deferredAsk.cancel(id)
        case .retry:
            await deferredAsk.retry(id)
        case .remove:
            await deferredAsk.remove(id)
            if job == nil { dismiss() }
        }
    }
}

private struct DeferredAskSavedAnswerView: View {
    let id: UUID
    @EnvironmentObject private var deferredAsk: DeferredAskController
    @State private var answer: OnlineAskSavedAnswer?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if let answer {
                OnlineAskSavedAnswerView(entry: answer)
            } else {
                List {
                    if isLoading {
                        ProgressView("Opening saved answer")
                    } else {
                        Text(error ?? "The saved answer is unavailable.").foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Saved online answer")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task(id: id) {
            defer { isLoading = false }
            do { answer = try await deferredAsk.savedAnswer(id) }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }
}

private extension DeferredAskJob {
    var displayState: String {
        switch state {
        case .queued: "Queued"
        case .running: "Sending"
        case .saved: "Saved"
        case .retryRequired: "Needs retry"
        case .cancelled: "Cancelled"
        }
    }
}
