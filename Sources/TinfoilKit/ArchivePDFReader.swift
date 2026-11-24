import PDFKit
import SwiftUI

struct ArchivePDFReader: View {
    let reader: ArchiveReader
    let archiveID: UUID
    let path: String
    var title: String?
    var initialPage: Int?
    @EnvironmentObject private var readingShelf: ReadingShelf
    @State private var document: PDFDocument?
    @State private var resourceTitle: String?
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var showsFind = false
    @FocusState private var findFocused: Bool
    @StateObject private var session = PDFReaderSession()

    var body: some View {
        Group {
            if let document {
                PDFSurface(document: document, initialPage: initialPage, session: session)
            } else if let errorMessage {
                ContentUnavailableView("Can't open document", systemImage: "doc", description: Text(errorMessage))
            } else {
                ProgressView("Opening document")
            }
        }
        .navigationTitle(documentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let readingLocation {
                ToolbarItem(placement: .topBarTrailing) {
                    ReadingBookmarkButton(location: readingLocation, title: documentTitle)
                }
            }
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
        .onChange(of: readingLocation, initial: true) {
            guard let readingLocation else { return }
            try? readingShelf.recordVisit(readingLocation, title: documentTitle)
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

    private var documentTitle: String { title ?? resourceTitle ?? "Document" }

    private var readingLocation: ReadingLocation? {
        guard let pageIndex = session.currentPageIndex else { return nil }
        return ReadingLocation(archiveID: archiveID, path: path, pageIndex: pageIndex, fragment: nil)
    }

    private var findBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Find in document", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($findFocused)
                    .submitLabel(.search)
                    .disabled(session.isSearching)
                    .onSubmit { submitFind() }
                    .onAppear { findFocused = !session.isSearching }
                Button("Find", action: submitFind)
                    .disabled(session.isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Done", action: closeFind)
            }
            HStack {
                if session.isSearching {
                    ProgressView("Searching document")
                } else if let count = session.matchCount {
                    if count == 0 {
                        Text("No matches")
                    } else if let position = session.currentPosition {
                        Text("\(position) of \(count)")
                            .monospacedDigit()
                            .accessibilityLabel("Match \(position) of \(count)")
                    }
                    Spacer()
                    Button("Previous match", systemImage: "chevron.up") { session.move(by: -1) }
                        .labelStyle(.iconOnly)
                        .disabled(count == 0)
                    Button("Next match", systemImage: "chevron.down") { session.move(by: 1) }
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
        .onChange(of: query) { session.queryChanged(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func submitFind() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        findFocused = false
        session.find(term)
    }

    private func closeFind() {
        showsFind = false
        findFocused = false
        query = ""
        session.clearResults()
    }

    private struct PDFSurface: UIViewRepresentable {
        let document: PDFDocument
        let initialPage: Int?
        let session: PDFReaderSession

        func makeCoordinator() -> PDFReaderSession { session }

        func makeUIView(context: Context) -> PDFView {
            let view = PDFView()
            view.document = document
            view.autoScales = true
            if let initialPage, (0..<document.pageCount).contains(initialPage),
               let page = document.page(at: initialPage) {
                view.go(to: page)
            }
            context.coordinator.attach(view)
            return view
        }

        func updateUIView(_ uiView: PDFView, context: Context) {}

        static func dismantleUIView(_ uiView: PDFView, coordinator: PDFReaderSession) {
            coordinator.detach(uiView)
        }
    }
}

@MainActor
private final class PDFReaderSession: NSObject, ObservableObject, PDFViewDelegate, PDFDocumentDelegate {
    // Only the main actor reads a copied result once it leaves the PDFKit callback.
    private struct MatchSnapshot: @unchecked Sendable {
        let selection: PDFSelection
    }

    @Published private(set) var isSearching = false
    @Published private(set) var matchCount: Int?
    @Published private(set) var currentPosition: Int?
    @Published private(set) var currentPageIndex: Int?

    private weak var view: PDFView?
    private var matches: [PDFSelection] = []
    private var keepsResults = false
    private var searchTerm: String?

    func attach(_ view: PDFView) {
        self.view = view
        view.delegate = self
        view.document?.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: view
        )
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.view === view else { return }
            self.updateCurrentPage(in: view)
        }
    }

    func detach(_ view: PDFView) {
        NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: view)
        guard self.view === view else { return }
        view.document?.delegate = nil
        view.document?.cancelFindString()
        self.view = nil
    }

    @objc private nonisolated func pageChanged(_ notification: Notification) {
        guard let source = notification.object as? PDFView else { return }
        let viewID = ObjectIdentifier(source)
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.view, ObjectIdentifier(view) == viewID else { return }
            self.updateCurrentPage(in: view)
        }
    }

    private func updateCurrentPage(in view: PDFView) {
        guard let document = view.document, let page = view.currentPage else { return }
        let index = document.index(for: page)
        guard (0..<document.pageCount).contains(index), currentPageIndex != index else { return }
        currentPageIndex = index
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
