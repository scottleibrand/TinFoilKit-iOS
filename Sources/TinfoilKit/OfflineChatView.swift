import FoundationModels
import SwiftUI

struct OfflineChatView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if #available(iOS 26, *), LibraryAnswer.isAvailable {
                    OfflineConversation()
                } else {
                    ContentUnavailableView {
                        Label("On-device model unavailable", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Offline Chat needs Apple Intelligence on iOS 26 or later. You can still search saved references in Ask.")
                    }
                }
            }
            .navigationTitle("Offline Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

@available(iOS 26, *)
private struct OfflineConversation: View {
    @FocusState private var composing: Bool
    @State private var draft = ""
    @State private var messages: [Message] = []
    @State private var session = OfflineConversation.makeSession()
    @State private var response: Task<Void, Never>?
    @State private var status: String?
    @State private var confirmingReset = false
    @State private var contextFull = false

    private static let maximumPromptLength = 1_500
    private var prompt: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if messages.isEmpty {
                        Text("Chat with the model on this phone. Use Ask to search and cite your saved references.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.isUser ? "You" : "Offline model").font(.subheadline.weight(.semibold))
                            if message.text.isEmpty {
                                ProgressView("Preparing reply")
                            } else {
                                Text(message.text).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    Color.clear.frame(height: 1).id("chat-end")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { scroll.scrollTo("chat-end", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New chat", systemImage: "plus.bubble") { confirmingReset = true }
                    .disabled(messages.isEmpty || response != nil)
            }
        }
        .alert("Start a new chat?", isPresented: $confirmingReset) {
            Button("Start new chat", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current conversation will be cleared.")
        }
        .onDisappear { response?.cancel() }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if prompt.count > Self.maximumPromptLength {
                Text("Shorten your message to 1,500 characters.").font(.footnote).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($composing)
                if let response {
                    Button("Stop", systemImage: "stop.circle") { response.cancel() }
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                        .disabled(contextFull || prompt.isEmpty || prompt.count > Self.maximumPromptLength)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial)
    }

    private func send() {
        let text = prompt
        guard response == nil, !contextFull, !text.isEmpty, text.count <= Self.maximumPromptLength else { return }
        draft = ""
        composing = false
        status = nil
        messages.append(Message(isUser: true, text: text))
        let reply = messages.count
        messages.append(Message(isUser: false, text: ""))
        response = Task { await respond(to: text, at: reply) }
    }

    private func respond(to prompt: String, at reply: Int) async {
        defer {
            if messages[reply].text.isEmpty { messages.remove(at: reply) }
            response = nil
        }
        do {
            for try await update in session.streamResponse(to: prompt, options: .init(maximumResponseTokens: 500)) {
                try Task.checkCancellation()
                messages[reply].text = update.content
            }
            try Task.checkCancellation()
            if messages[reply].text.isEmpty { status = "The model returned an empty reply." }
        } catch is CancellationError {
            status = "Reply stopped."
        } catch {
            if Task.isCancelled {
                status = "Reply stopped."
            } else if Self.contextExceeded(error) {
                contextFull = true
                status = "This conversation has reached the model’s limit. Start a new chat to continue."
            } else {
                status = "The on-device model couldn’t finish this reply. Try a shorter message or start a new chat."
            }
        }
    }

    private func reset() {
        guard response == nil else { return }
        session = Self.makeSession()
        messages.removeAll()
        draft = ""
        status = nil
        contextFull = false
    }

    private static func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: "Be clear and concise. Say when you’re uncertain. Give general help and avoid inventing sources.")
    }

    private static func contextExceeded(_ error: Error) -> Bool {
        if #available(iOS 27, *), let error = error as? LanguageModelError,
           case .contextSizeExceeded = error { return true }
        if let error = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = error { return true }
        return false
    }

    private struct Message: Identifiable {
        let id = UUID()
        let isUser: Bool
        var text: String
    }
}
