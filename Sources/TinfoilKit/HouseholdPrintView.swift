import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HouseholdPrintView: View {
    let snapshot: HouseholdSnapshot
    @State private var references: [HouseholdPrinting.AvailableReference]?
    @State private var referenceError: String?
    @State private var includeResourceRunway = false

    var body: some View {
        List {
            Section("Your household") {
                if snapshot.resources?.isEmpty == false {
                    Toggle("Include supply runway", isOn: $includeResourceRunway)
                }
                NavigationLink {
                    PrintablePDFView(title: "Household essentials", allowsSharing: true) { [includeResourceRunway] in
                        try await HouseholdPrinting.householdPDF(for: snapshot,
                                                                 includeResourceRunway: includeResourceRunway)
                    }
                } label: {
                    Label("Open household sheet", systemImage: "doc.text")
                }
                Text("Includes your notes, home, saved pins, and nearby services from installed place data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Reference pages") {
                if let referenceError {
                    Text(referenceError).foregroundStyle(.secondary)
                } else if let references {
                    if references.isEmpty {
                        Text("Download the Water Treatment or Field Medicine pack to find printable guides here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(references) { available in
                        NavigationLink {
                            PrintablePDFView(title: available.reference.title, allowsSharing: false) {
                                let task = Task.detached(priority: .userInitiated) { try available.printablePDF() }
                                return try await withTaskCancellationHandler { try await task.value }
                                    onCancel: { task.cancel() }
                            }
                        } label: {
                            referenceRow(available)
                        }
                    }
                } else {
                    ProgressView("Checking installed references")
                }
            }
        }
        .navigationTitle("Print the essentials")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { references = try await HouseholdPrinting.installedReferences() }
            catch is CancellationError {}
            catch { referenceError = error.localizedDescription }
        }
    }

    private func referenceRow(_ available: HouseholdPrinting.AvailableReference) -> some View {
        let reference = available.reference
        return VStack(alignment: .leading, spacing: 4) {
            Text(reference.title)
            Text("\(reference.document) · pp. \(reference.pages.lowerBound)–\(reference.pages.upperBound)")
                .font(.subheadline)
            Text(available.attribution).font(.footnote)
        }
        .foregroundStyle(.primary)
    }
}

private struct PrintablePDFView: View {
    let title: String
    let allowsSharing: Bool
    let load: () async throws -> Data

    @State private var data: Data?
    @State private var document: PDFDocument?
    @State private var error: String?
    @State private var printError: String?

    var body: some View {
        Group {
            if let document {
                PDFPreview(document: document)
            } else if let error {
                ContentUnavailableView("Couldn’t open the PDF", systemImage: "printer", description: Text(error))
            } else {
                ProgressView("Preparing print preview")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let data {
                ToolbarItemGroup(placement: .primaryAction) {
                    if allowsSharing {
                        ShareLink(item: HouseholdPrintPDF(data: data), preview: SharePreview(title))
                    }
                    SystemPrintButton(data: data, title: title) { printError = $0 }
                        .fixedSize()
                }
            }
        }
        .alert("Couldn’t print the PDF", isPresented: Binding(
            get: { printError != nil }, set: { if !$0 { printError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(printError ?? "") }
        .task {
            guard document == nil else { return }
            do {
                let result = try await load()
                guard let pdf = PDFDocument(data: result) else { throw CocoaError(.fileReadCorruptFile) }
                document = pdf
                data = result
            } catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct HouseholdPrintPDF: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { $0.data }
            .suggestedFileName("Household essentials.pdf")
    }
}

private struct PDFPreview: UIViewRepresentable {
    let document: PDFDocument

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.delegate = context.coordinator
        view.document = document
        view.autoScales = true
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}

    final class Coordinator: NSObject, PDFViewDelegate {
        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
    }
}

private struct SystemPrintButton: UIViewRepresentable {
    let data: Data
    let title: String
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(request: self)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "printer"), for: .normal)
        button.accessibilityLabel = "Print"
        button.addTarget(context.coordinator, action: #selector(Coordinator.printTapped(_:)), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.request = self
    }

    final class Coordinator: NSObject {
        var request: SystemPrintButton

        init(request: SystemPrintButton) {
            self.request = request
        }

        @MainActor
        @objc func printTapped(_ button: UIButton) {
            let request = self.request
            guard UIPrintInteractionController.isPrintingAvailable,
                  UIPrintInteractionController.canPrint(request.data) else {
                request.onError("Printing is unavailable on this device.")
                return
            }

            let controller = UIPrintInteractionController.shared
            let info = UIPrintInfo(dictionary: nil)
            info.jobName = request.title
            controller.printInfo = info
            controller.printingItem = request.data
            let completion: UIPrintInteractionController.CompletionHandler = { _, _, error in
                if let error { request.onError(error.localizedDescription) }
            }
            let presented: Bool
            if button.traitCollection.userInterfaceIdiom == .pad {
                presented = controller.present(from: button.bounds, in: button, animated: true, completionHandler: completion)
            } else {
                presented = controller.present(animated: true, completionHandler: completion)
            }
            if !presented { request.onError("Print options could not be shown.") }
        }
    }
}
