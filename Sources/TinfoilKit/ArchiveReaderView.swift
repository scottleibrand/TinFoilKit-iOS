import PDFKit
import SwiftUI
import WebKit
import ZIMArchive

struct ArchiveReaderView: View {
    let library: InstalledLibrary
    let archive: InstalledArchive
    var articlePath: String? = nil
    @State private var reader: ArchiveReader?
    @State private var page: URL?
    @State private var documents: [ZIMArchive.PDFEntry]?
    @State private var pdfReference: ArchivePDFReference?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let reader, let pdfReference {
                ArchivePDFReader(reader: reader, path: pdfReference.path, initialPage: pdfReference.pageIndex)
            } else if let reader, let documents {
                if documents.isEmpty {
                    ContentUnavailableView("No documents", systemImage: "doc")
                } else {
                    List(documents) { document in
                        NavigationLink(document.title) {
                            ArchivePDFReader(reader: reader, path: document.path, title: document.title)
                        }
                    }
                }
            } else if let reader, let page {
                ArchiveWebView(reader: reader, page: page)
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
                if let articlePath, let reference = ArchivePDFReference(articlePath: articlePath) {
                    pdfReference = reference
                    self.reader = reader
                    return
                }
                if articlePath == nil, let pack = archive.pack, PackDownloads.usesPDFDirectory(pack) {
                    documents = try await reader.pdfEntries().sorted {
                        $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    }
                    self.reader = reader
                    return
                }
                let path: String
                if let articlePath {
                    path = articlePath
                } else {
                    path = try await reader.mainPath()
                }
                guard let url = ArchiveWebView.url(for: path) else { throw URLError(.badURL) }
                self.reader = reader
                page = url
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private actor ArchiveReader {
    let file: URL
    private var archive: ZIMArchive?

    init(file: URL) {
        self.file = file
    }

    func mainPath() throws -> String {
        try open().mainArticle().path
    }

    func resource(at path: String) throws -> ZIMArchive.Resource {
        try open().resource(at: path)
    }

    func pdfEntries() throws -> [ZIMArchive.PDFEntry] {
        try open().pdfEntries()
    }

    private func open() throws -> ZIMArchive {
        if let archive { return archive }
        let archive = try ZIMArchive(fileURL: file)
        self.archive = archive
        return archive
    }
}

private struct ArchivePDFReader: View {
    let reader: ArchiveReader
    let path: String
    var title: String?
    var initialPage: Int?
    @State private var document: PDFDocument?
    @State private var resourceTitle: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let document {
                PDFSurface(document: document, initialPage: initialPage)
            } else if let errorMessage {
                ContentUnavailableView("Can't open document", systemImage: "doc", description: Text(errorMessage))
            } else {
                ProgressView("Opening document")
            }
        }
        .navigationTitle(title ?? resourceTitle ?? "Document")
        .navigationBarTitleDisplayMode(.inline)
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

    private struct PDFSurface: UIViewRepresentable {
        let document: PDFDocument
        let initialPage: Int?

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context: Context) -> PDFView {
            let view = PDFView()
            view.delegate = context.coordinator
            view.document = document
            view.autoScales = true
            if let initialPage, let page = document.page(at: initialPage) {
                view.go(to: page)
            }
            return view
        }

        func updateUIView(_ uiView: PDFView, context: Context) {}

        final class Coordinator: NSObject, PDFViewDelegate {
            // Keep archive-linked navigation local, as in the HTML reader.
            func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
        }
    }
}

private struct ArchiveWebView: UIViewRepresentable {
    let reader: ArchiveReader
    let page: URL

    static func url(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "zim"
        components.host = "archive"
        components.path = "/" + path
        return components.url
    }

    func makeCoordinator() -> Loader {
        Loader(reader: reader)
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
        context.coordinator.open(page, in: view)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Loader: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
        private let reader: ArchiveReader
        private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

        init(reader: ArchiveReader) {
            self.reader = reader
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
            guard let url = urlSchemeTask.request.url, Self.isArchive(url) else {
                urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
                return
            }
            let id = ObjectIdentifier(urlSchemeTask as AnyObject)
            tasks[id] = Task { @MainActor in
                defer { tasks[id] = nil }
                do {
                    let resource = try await reader.resource(at: String(url.path.dropFirst()))
                    guard !Task.isCancelled else { return }
                    let response = URLResponse(
                        url: url,
                        mimeType: resource.mimeType,
                        expectedContentLength: resource.data.count,
                        textEncodingName: nil
                    )
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(resource.data)
                    urlSchemeTask.didFinish()
                } catch {
                    if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
                }
            }
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.cancel()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            decisionHandler(url.map(Self.isArchive) == true || url?.absoluteString == "about:blank" ? .allow : .cancel)
        }

        private static func isArchive(_ url: URL) -> Bool {
            url.scheme == "zim" && url.host == "archive"
        }
    }
}
