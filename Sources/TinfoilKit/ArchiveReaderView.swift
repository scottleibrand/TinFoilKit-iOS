import SwiftUI
import WebKit
import ZIMArchive

struct ArchiveReaderView: View {
    let library: InstalledLibrary
    let archive: InstalledArchive
    var articlePath: String? = nil
    var initialPageIndex: Int? = nil
    var initialFragment: String? = nil
    @State private var reader: ArchiveReader?
    @State private var page: URL?
    @State private var opensDocumentList = false
    @State private var pdfReference: (path: String, pageIndex: Int)?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let reader, let pdfReference {
                ArchivePDFReader(reader: reader, archiveID: archive.id, path: pdfReference.path,
                                 initialPage: pdfReference.pageIndex)
            } else if let reader, opensDocumentList {
                ArchiveDocumentList(reader: reader, archiveID: archive.id)
            } else if let reader, let page {
                ArchiveHTMLReader(reader: reader, page: page, archive: archive)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink {
                                ArchiveDocumentList(reader: ArchiveReader(file: reader.file), archiveID: archive.id)
                                    .navigationTitle("PDF documents")
                            } label: {
                                Label("PDF documents", systemImage: "doc.on.doc")
                            }
                        }
                    }
            } else if let errorMessage {
                ContentUnavailableView("Can't open archive", systemImage: "book.closed", description: Text(errorMessage))
            } else {
                ProgressView("Opening archive")
            }
        }
        .navigationTitle(archive.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let file = await library.fileURL(for: archive.id)
                let reader = ArchiveReader(file: file)
                if let articlePath, let initialPageIndex {
                    pdfReference = (articlePath, initialPageIndex)
                    self.reader = reader
                    return
                }
                if let articlePath, let reference = ArchivePDFReference(articlePath: articlePath) {
                    pdfReference = (reference.path, reference.pageIndex)
                    self.reader = reader
                    return
                }
                if articlePath == nil, let pack = archive.pack, PackDownloads.usesPDFDirectory(pack) {
                    opensDocumentList = true
                    self.reader = reader
                    return
                }
                let path: String
                if let articlePath {
                    path = articlePath
                } else {
                    do {
                        let landing = try await reader.landingPage()
                        if landing.mimeType == "application/pdf" {
                            pdfReference = (landing.path, 0)
                            self.reader = reader
                            return
                        }
                        path = landing.path
                    } catch {
                        // A documents-only import can have no readable landing article.
                        guard !Task.isCancelled else { return }
                        opensDocumentList = true
                        self.reader = reader
                        return
                    }
                }
                guard let url = ArchiveWebAddress.url(for: path, fragment: initialFragment) else { throw URLError(.badURL) }
                self.reader = reader
                page = url
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ArchiveDocumentList: View {
    let reader: ArchiveReader
    let archiveID: UUID
    @State private var documents: [ZIMArchive.PDFEntry]?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let documents {
                if documents.isEmpty {
                    ContentUnavailableView("No PDF documents", systemImage: "doc")
                } else {
                    List(documents) { document in
                        NavigationLink(document.title) {
                            ArchivePDFReader(reader: reader, archiveID: archiveID, path: document.path,
                                             title: document.title)
                        }
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView("Can't list documents", systemImage: "doc", description: Text(errorMessage))
            } else {
                ProgressView("Finding PDF documents")
            }
        }
        .task {
            do {
                let entries = try await reader.pdfEntries()
                try Task.checkCancellation()
                documents = entries
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

actor ArchiveReader {
    let file: URL
    private var archive: ZIMArchive?

    init(file: URL) {
        self.file = file
    }

    func landingPage() throws -> (path: String, mimeType: String) {
        let main = try open().mainArticle()
        return (main.path, main.mimeType)
    }

    func resource(at path: String) throws -> ZIMArchive.Resource {
        try open().resource(at: path)
    }

    enum WebResource: Sendable {
        case direct(path: String, info: ZIMArchive.DirectResourceInfo)
        case buffered(ZIMArchive.Resource)

        var properties: (mimeType: String, count: Int) {
            switch self {
            case let .direct(_, info): (info.mimeType, info.byteCount)
            case let .buffered(resource): (resource.mimeType, resource.data.count)
            }
        }
    }

    func webResource(for request: URL) throws -> WebResource {
        let candidates = ArchiveWebAddress.candidates(in: request)
        guard let first = candidates.first else { throw URLError(.unsupportedURL) }
        let path = candidates.count == 1 ? first : try resolvedPath(in: candidates) ?? first
        let archive = try open()
        if let info = try archive.directResourceInfo(at: path) { return .direct(path: path, info: info) }
        return .buffered(try archive.resource(at: path))
    }

    func webResourceBytes(at path: String, offset: Int, count: Int) throws -> Data {
        try Task.checkCancellation()
        return try open().directResourceBytes(at: path, offset: offset, count: count)
    }

    /// Opens supported large PDF entries from a file instead of a single buffer.
    func prepareLargePDF(at path: String) throws -> TemporaryArchivePDF? {
        let archive = try open()
        let info = try archive.directResourceInfo(at: path)
        let directory = URL.temporaryDirectory
        if let info {
            guard info.mimeType == "application/pdf", info.byteCount > 32 * 1024 * 1024 else { return nil }
            let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = capacity.volumeAvailableCapacityForImportantUsage, available < Int64(info.byteCount) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        try Task.checkCancellation()
        let temporary = TemporaryArchivePDF(url: directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf"))
        guard FileManager.default.createFile(atPath: temporary.url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: temporary.url)
        defer { try? output.close() }
        if let info {
            var offset = 0
            while offset < info.byteCount {
                try Task.checkCancellation()
                let count = min(1_048_576, info.byteCount - offset)
                try output.write(contentsOf: archive.directResourceBytes(at: path, offset: offset, count: count))
                offset += count
            }
        } else if try !archive.extractCompressedPDF(at: path, to: output.fileDescriptor) {
            return nil
        }
        try output.close()
        try Task.checkCancellation()
        return temporary
    }

    func canonicalURL(for request: URL) throws -> URL? {
        guard let path = try resolvedPath(in: ArchiveWebAddress.candidates(in: request)) else { return nil }
        return ArchiveWebAddress.canonicalURL(for: path, relativeTo: request)
    }

    private func resolvedPath(in candidates: [String]) throws -> String? {
        guard !candidates.isEmpty else { return nil }
        let archive = try open()
        for key in candidates {
            if let path = try archive.resolvedPath(at: key) { return path }
        }
        return nil
    }

    func pdfEntries() throws -> [ZIMArchive.PDFEntry] {
        try open().pdfEntries().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func open() throws -> ZIMArchive {
        if let archive { return archive }
        let archive = try ZIMArchive(fileURL: file)
        self.archive = archive
        return archive
    }
}

private struct ArchiveHTMLReader: View {
    let reader: ArchiveReader
    let page: URL
    let archive: InstalledArchive
    @EnvironmentObject private var readingShelf: ReadingShelf
    @StateObject private var controls = ArchiveWebControls()

    var body: some View {
        ArchiveWebView(reader: reader, page: page, controls: controls)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Back in archive", systemImage: "chevron.left") { controls.goBack() }
                        .disabled(!controls.canGoBack)
                    Button("Forward in archive", systemImage: "chevron.right") { controls.goForward() }
                        .disabled(!controls.canGoForward)
                    Button("Find on page", systemImage: "doc.text.magnifyingglass") { controls.findOnPage() }
                        .disabled(!controls.canFind)
                    if let page = controls.readingPage {
                        ReadingBookmarkButton(location: location(for: page), title: page.title ?? archive.title)
                            .disabled(!controls.canFind)
                    }
                }
            }
            .onChange(of: controls.readingPage, initial: true) {
                guard let page = controls.readingPage else { return }
                try? readingShelf.recordVisit(location(for: page), title: page.title ?? archive.title)
            }
    }

    private func location(for page: ArchiveWebControls.ReadingPage) -> ReadingLocation {
        ReadingLocation(archiveID: archive.id, path: page.path, fragment: page.fragment)
    }
}

@MainActor
private final class ArchiveWebControls: ObservableObject {
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var canFind = false
    @Published private(set) var readingPage: ReadingPage?

    struct ReadingPage: Equatable {
        let path: String
        let fragment: String?
        let title: String?
    }

    private weak var view: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    func attach(to view: WKWebView) {
        self.view = view
        let refresh = { [weak self, weak view] in
            DispatchQueue.main.async {
                guard let self, let view, self.view === view else { return }
                self.canGoBack = view.canGoBack
                self.canGoForward = view.canGoForward
                self.canFind = view.url?.scheme == "zim" && !view.isLoading
                // In-page links can change the fragment without finishing a new document load.
                if let current = self.readingPage, let url = view.url, self.canFind,
                   ArchiveWebAddress.path(in: url) == current.path,
                   let next = Self.makeReadingPage(url: url, title: current.title), next != current {
                    self.readingPage = next
                }
            }
        }
        observations = [
            view.observe(\.canGoBack, options: [.initial, .new]) { _, _ in refresh() },
            view.observe(\.canGoForward, options: [.new]) { _, _ in refresh() },
            view.observe(\.isLoading, options: [.new]) { _, _ in refresh() },
            view.observe(\.url, options: [.new]) { _, _ in refresh() }
        ]
    }

    func detach(from view: WKWebView) {
        guard self.view === view else { return }
        self.view = nil
        observations.removeAll()
    }

    func didFinish(in view: WKWebView) {
        guard self.view === view, let url = view.url else { return }
        readingPage = Self.makeReadingPage(url: url, title: view.title)
    }

    private static func makeReadingPage(url: URL, title: String?) -> ReadingPage? {
        guard let path = ArchiveWebAddress.path(in: url), !path.isEmpty else { return nil }
        let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReadingPage(path: path, fragment: fragment?.isEmpty == false ? fragment : nil,
                           title: title?.isEmpty == false ? title : nil)
    }

    func goBack() { view?.goBack() }
    func goForward() { view?.goForward() }

    func findOnPage() {
        view?.findInteraction?.presentFindNavigator(showingReplace: false)
    }
}

private struct ArchiveWebView: UIViewRepresentable {
    let reader: ArchiveReader
    let page: URL
    let controls: ArchiveWebControls

    func makeCoordinator() -> Loader {
        Loader(reader: reader, controls: controls)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "zim")

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = true
        view.isFindInteractionEnabled = true
        controls.attach(to: view)
        context.coordinator.open(page, in: view)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Loader) {
        coordinator.close(uiView)
    }

    final class Loader: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
        private let reader: ArchiveReader
        private let controls: ArchiveWebControls
        private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var navigationTask: Task<Void, Never>?

        init(reader: ArchiveReader, controls: ArchiveWebControls) {
            self.reader = reader
            self.controls = controls
        }

        @MainActor
        func close(_ webView: WKWebView) {
            controls.detach(from: webView)
            navigationTask?.cancel()
            navigationTask = nil
            webView.stopLoading()
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
        }

        func open(_ url: URL, in webView: WKWebView) {
            // Install the network block before any archived HTML can load.
            let rules = """
                [
                    {"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},
                    {"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},
                    {"trigger":{"url-filter":"^file:"},"action":{"type":"block"}},
                    {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}}
                ]
                """
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "ArchiveNetworkBlock", encodedContentRuleList: rules
            ) { [weak webView] list, _ in
                Task { @MainActor in
                    guard let webView else { return }
                    guard let list else {
                        webView.loadHTMLString("<p>The offline reader could not start.</p>", baseURL: nil)
                        return
                    }
                    webView.configuration.userContentController.add(list)
                    webView.load(URLRequest(url: url))
                }
            }
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, ArchiveWebAddress.path(in: url) != nil else {
                urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
                return
            }
            let request = urlSchemeTask.request
            let headOnly = request.httpMethod == "HEAD"
            let rangeHeader = request.httpMethod == "GET" || request.httpMethod == nil
                ? request.value(forHTTPHeaderField: "Range") : nil
            let id = ObjectIdentifier(urlSchemeTask as AnyObject)
            tasks[id] = Task { @MainActor in
                defer { tasks[id] = nil }
                do {
                    let resource = try await reader.webResource(for: url)
                    try Task.checkCancellation()
                    let (mimeType, count) = resource.properties
                    let selection = ArchiveReadRange.parse(rangeHeader, count: count)
                    let range: Range<Int>
                    switch selection {
                    case .full:
                        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mimeType,
                            expectedContentLength: count, textEncodingName: nil))
                        range = 0..<count
                    case .partial(let selected):
                        urlSchemeTask.didReceive(try rangeResponse(url, status: 206, mimeType: mimeType,
                            length: selected.count, contentRange: selection.contentRange(count: count)))
                        range = selected
                    case .unsatisfiable:
                        urlSchemeTask.didReceive(try rangeResponse(url, status: 416, mimeType: mimeType,
                            length: 0, contentRange: selection.contentRange(count: count)))
                        range = 0..<0
                    }
                    if !headOnly, !range.isEmpty {
                        switch resource {
                        case let .buffered(item):
                            urlSchemeTask.didReceive(Data(item.data[range]))
                        case let .direct(path, _):
                            var offset = range.lowerBound
                            while offset < range.upperBound {
                                let count = min(256 * 1024, range.upperBound - offset)
                                let data = try await reader.webResourceBytes(at: path, offset: offset, count: count)
                                try Task.checkCancellation()
                                urlSchemeTask.didReceive(data)
                                offset += count
                            }
                        }
                    }
                    if !Task.isCancelled { urlSchemeTask.didFinish() }
                } catch {
                    if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
                }
            }
        }

        private func rangeResponse(_ url: URL, status: Int, mimeType: String, length: Int,
                                   contentRange: String?) throws -> HTTPURLResponse {
            guard let contentRange, let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Accept-Ranges": "bytes", "Content-Range": contentRange,
                               "Content-Type": mimeType, "Content-Length": String(length)]
            ) else { throw URLError(.badServerResponse) }
            return response
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.cancel()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let request = navigationAction.request
            guard let url = request.url, ArchiveWebAddress.path(in: url) != nil else {
                decisionHandler(request.url?.absoluteString == "about:blank" ? .allow : .cancel)
                return
            }
            guard navigationAction.targetFrame?.isMainFrame == true,
                  request.httpMethod == nil || request.httpMethod == "GET" else {
                decisionHandler(.allow)
                return
            }
            navigationTask?.cancel()
            // A navigation must have the final archive URL before WebKit resolves relative links.
            navigationTask = Task { @MainActor [weak self, weak webView] in
                guard let self else {
                    decisionHandler(.cancel)
                    return
                }
                let canonical = try? await reader.canonicalURL(for: url)
                guard !Task.isCancelled, let webView else {
                    decisionHandler(.cancel)
                    return
                }
                navigationTask = nil
                guard let canonical, canonical != url else {
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
                var redirected = request
                redirected.url = canonical
                webView.load(redirected)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            controls.didFinish(in: webView)
        }
    }
}
