import CoreGraphics
import FoundationModels
import PhotosUI
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
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoRequest: PhotoRequest?
    @State private var photo: OfflineChatPhoto?

    private static let maximumPromptLength = 1_500
    private var prompt: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var supportsPhotos: Bool {
        if #available(iOS 27, *) { return SystemLanguageModel.default.capabilities.contains(.vision) }
        return false
    }

    private var canSend: Bool {
        response == nil && photoRequest == nil && (photo == nil || supportsPhotos) && !contextFull && !prompt.isEmpty &&
            prompt.count <= Self.maximumPromptLength
    }

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
                            if let photo = message.photo {
                                Image(decorative: photo, scale: 1)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 200, alignment: .leading)
                                    .accessibilityLabel("Attached photo")
                            }
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
                            .disabled(messages.isEmpty || response != nil || photoRequest != nil)
            }
        }
        .alert("Start a new chat?", isPresented: $confirmingReset) {
            Button("Start new chat", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current conversation will be cleared.")
        }
        .onChange(of: selectedPhoto) {
            guard let item = selectedPhoto else { return }
            selectedPhoto = nil
            photo = nil
            status = nil
            photoRequest = PhotoRequest(item: item)
        }
        .task(id: photoRequest?.id) {
            if let request = photoRequest { await loadPhoto(request) }
        }
        .onDisappear { response?.cancel() }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if prompt.count > Self.maximumPromptLength {
                Text("Shorten your message to 1,500 characters.").font(.footnote).foregroundStyle(.secondary)
            }
            if photoRequest != nil {
                HStack {
                    ProgressView("Preparing photo")
                    Spacer()
                    Button("Cancel photo", role: .cancel) { photoRequest = nil }
                        .buttonStyle(.plain)
                }
            } else if let photo {
                HStack(spacing: 8) {
                    Image(decorative: photo.preview, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                    Text("Photo attached")
                    Spacer()
                    Button("Remove photo", systemImage: "xmark.circle") { self.photo = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                }
            }
            HStack(alignment: .bottom) {
                if supportsPhotos {
                    PhotosPicker(selection: $selectedPhoto, matching: .images, preferredItemEncoding: .current) {
                        Label(photo == nil ? "Attach photo" : "Replace photo", systemImage: "photo")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .disabled(response != nil || contextFull || photoRequest != nil)
                }
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($composing)
                if let response {
                    Button("Stop", systemImage: "stop.circle") { response.cancel() }
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                        .disabled(!canSend)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial)
    }

    private func send() {
        guard canSend else { return }
        let text = prompt
        let photo = self.photo
        self.photo = nil
        draft = ""
        composing = false
        status = nil
        messages.append(Message(isUser: true, text: text, photo: photo?.preview))
        let reply = messages.count
        messages.append(Message(isUser: false, text: ""))
        response = Task { await respond(to: text, photo: photo?.image, at: reply) }
    }

    private func loadPhoto(_ request: PhotoRequest) async {
        defer { if photoRequest?.id == request.id { photoRequest = nil } }
        do {
            let attachment = try await request.item.loadTransferable(type: OfflineChatPhoto.self)
            try Task.checkCancellation()
            guard photoRequest?.id == request.id else { return }
            photo = attachment
            if attachment == nil { status = OfflineChatPhoto.ImportError.invalidPhoto.localizedDescription }
        } catch is CancellationError {
        } catch let error as OfflineChatPhoto.ImportError {
            if photoRequest?.id == request.id, !Task.isCancelled { status = error.localizedDescription }
        } catch {
            if photoRequest?.id == request.id, !Task.isCancelled {
                status = "This photo could not be loaded. Try a photo available on this phone."
            }
        }
    }

    private func respond(to prompt: String, photo: CGImage?, at reply: Int) async {
        defer {
            if messages[reply].text.isEmpty { messages.remove(at: reply) }
            response = nil
        }
        do {
            let options = GenerationOptions(maximumResponseTokens: 500)
            let stream: LanguageModelSession.ResponseStream<String>
            if #available(iOS 27, *), let photo {
                stream = session.streamResponse(options: options) {
                    prompt
                    Attachment(photo)
                }
            } else {
                stream = session.streamResponse(to: prompt, options: options)
            }
            for try await update in stream {
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
        photo = nil
        selectedPhoto = nil
        photoRequest = nil
        status = nil
        contextFull = false
    }

    private static func makeSession() -> LanguageModelSession {
        LanguageModelSession(model: SystemLanguageModel.default,
                             instructions: "Be clear and concise. Say when you’re uncertain. Give general help and avoid inventing sources.")
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
        var photo: CGImage? = nil
    }

    private struct PhotoRequest {
        let id = UUID()
        let item: PhotosPickerItem
    }
}
