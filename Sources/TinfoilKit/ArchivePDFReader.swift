import PDFKit
import SwiftUI

struct ArchivePDFReader: View {
    let reader: ArchiveReader
    let path: String
    var title: String?
    var initialPage: Int?
    @State private var document: PDFDocument?
    @State private var resourceTitle: String?
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var showsFind = false
    @FocusState private var findFocused: Bool
    @StateObject private var search = PDFSearchSession()

    var body: some View {
        Group {
            if let document {
                PDFSurface(document: document, initialPage: initialPage, search: search)
            } else if let errorMessage {
                ContentUnavailableView("Can't open document", systemImage: "doc", description: Text(errorMessage))
            } else {
                ProgressView("Opening document")
            }
        }
        .navigationTitle(title ?? resourceTitle ?? "Document")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if document != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Find in document", systemImage: "magnifyingglass") {
                        if showsFind {
                            closeFind()
                        } else {
                            showsFind = true
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsFind { findBar }
        }
        .task {
            do {
                let resource = try await reader.resource(at: path)
                guard resource.mimeType == "application/pdf", let document = PDFDocument(data: resource.data) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                resourceTitle = resource.title.isEmpty ? nil : resource.title
                self.document = document
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var findBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Find in document", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($findFocused)
                    .submitLabel(.search)
                    .disabled(search.isSearching)
                    .onSubmit { submitFind() }
                    .onAppear { findFocused = !search.isSearching }
                Button("Find", action: submitFind)
                    .disabled(search.isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Done", action: closeFind)
            }
            HStack {
                if search.isSearching {
                    ProgressView("Searching document")
                } else if let count = search.matchCount {
                    if count == 0 {
                        Text("No matches")
                    } else if let position = search.currentPosition {
                        Text("\(position) of \(count)")
                            .monospacedDigit()
                            .accessibilityLabel("Match \(position) of \(count)")
                    }
                    Spacer()
                    Button("Previous match", systemImage: "chevron.up") { search.move(by: -1) }
                        .labelStyle(.iconOnly)
                        .disabled(count == 0)
                    Button("Next match", systemImage: "chevron.down") { search.move(by: 1) }
                        .labelStyle(.iconOnly)
                        .disabled(count == 0)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .onChange(of: query) { search.queryChanged(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func submitFind() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        findFocused = false
        search.find(term)
    }

    private func closeFind() {
        showsFind = false
        findFocused = false
        query = ""
        search.clearResults()
    }

    private struct PDFSurface: UIViewRepresentable {
        let document: PDFDocument
        let initialPage: Int?
        let search: PDFSearchSession

        func makeCoordinator() -> PDFSearchSession { search }

        func makeUIView(context: Context) -> PDFView {
            let view = PDFView()
            view.document = document
            view.autoScales = true
            context.coordinator.attach(view)
            if let initialPage, let page = document.page(at: initialPage) {
                view.go(to: page)
            }
            return view
        }

        func updateUIView(_ uiView: PDFView, context: Context) {}

        static func dismantleUIView(_ uiView: PDFView, coordinator: PDFSearchSession) {
            coordinator.detach(uiView)
        }
    }
}

@MainActor
private final class PDFSearchSession: NSObject, ObservableObject, PDFViewDelegate, PDFDocumentDelegate {
    // Only the main actor reads a copied result once it leaves the PDFKit callback.
    private struct MatchSnapshot: @unchecked Sendable {
        let selection: PDFSelection
    }

    @Published private(set) var isSearching = false
    @Published private(set) var matchCount: Int?
    @Published private(set) var currentPosition: Int?

    private weak var view: PDFView?
    private var matches: [PDFSelection] = []
    private var keepsResults = false
    private var searchTerm: String?

    func attach(_ view: PDFView) {
        self.view = view
        view.delegate = self
        view.document?.delegate = self
    }

    func detach(_ view: PDFView) {
        guard self.view === view else { return }
        view.document?.delegate = nil
        view.document?.cancelFindString()
        self.view = nil
    }

    func find(_ term: String) {
        guard !isSearching, let document = view?.document else { return }
        clearResults()
        keepsResults = true
        searchTerm = term
        isSearching = true
        document.beginFindString(term, withOptions: [.caseInsensitive])
    }

    func clearResults() {
        keepsResults = false
        searchTerm = nil
        matches.removeAll()
        matchCount = nil
        currentPosition = nil
        view?.clearSelection()
    }

    func queryChanged(_ term: String) {
        if term != searchTerm { clearResults() }
    }

    func move(by offset: Int) {
        guard let currentPosition, !matches.isEmpty else { return }
        let index = (currentPosition - 1 + offset + matches.count) % matches.count
        select(at: index)
    }

    private func select(at index: Int) {
        guard let view else { return }
        let selection = matches[index]
        currentPosition = index + 1
        view.setCurrentSelection(selection, animate: false)
        view.go(to: selection)
    }

    nonisolated func didMatchString(_ instance: PDFSelection) {
        guard let copy = instance.copy() as? PDFSelection else { return }
        let result = MatchSnapshot(selection: copy)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.keepsResults, self.view != nil else { return }
            self.matches.append(result.selection)
        }
    }

    nonisolated func documentDidEndDocumentFind(_ notification: Notification) {
        guard let document = notification.object as? PDFDocument else { return }
        let completedDocument = ObjectIdentifier(document)
        DispatchQueue.main.async { [weak self] in
            guard let self, let document = self.view?.document,
                  ObjectIdentifier(document) == completedDocument else { return }
            self.isSearching = false
            guard self.keepsResults else { return }
            self.matchCount = self.matches.count
            if !self.matches.isEmpty { self.select(at: 0) }
        }
    }

    // Keep archive-linked navigation local, as in the HTML reader.
    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
}
