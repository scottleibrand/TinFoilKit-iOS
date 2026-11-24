import SwiftUI
import UniformTypeIdentifiers

struct HouseholdFilesView: View {
    @ObservedObject var household: HouseholdStore
    let restore: (HouseholdSnapshot) throws -> Void

    @State private var choosingImport = false
    @State private var reading = false
    @State private var pending: ImportPreview?
    @State private var document: ExportDocument?
    @State private var exportKind: ExportKind = .backup
    @State private var exporting = false
    @State private var errorMessage: String?
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                Button("Import household file", systemImage: "square.and.arrow.down") {
                    choosingImport = true
                }
                .disabled(reading)
                if reading { ProgressView("Reading file") }
                if let status { Text(status).foregroundStyle(.secondary) }
                if household.loadError != nil {
                    Button("Start a new household", role: .destructive) {
                        pending = ImportPreview(before: household.snapshot, after: HouseholdSnapshot(), startsFresh: true)
                    }
                    .disabled(reading)
                }
            } footer: {
                Text("Choose an iPhone household backup or a desktop Tinfoil Kit notes.txt or places.json file.")
            }

            Section {
                Button("Export household backup", systemImage: "square.and.arrow.up") {
                    beginExport(.backup)
                }
                Menu("Export for desktop Tinfoil Kit") {
                    Button("Notes (notes.txt)") { beginExport(.notes) }
                    Button("Home and pins (places.json)") { beginExport(.places) }
                }
            } footer: {
                Text("The backup contains your notes, home, and pins. Save it somewhere you trust.")
            }
            .disabled(household.loadError != nil)
        }
        .navigationTitle("Import and export")
        .fileImporter(isPresented: $choosingImport, allowedContentTypes: [.json, .plainText]) { result in
            Task { await prepareImport(result) }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: exportKind.contentType,
                      defaultFilename: exportKind.filename) { result in
            if case let .failure(error) = result { errorMessage = error.localizedDescription }
            document = nil
        }
        .confirmationDialog(pending?.startsFresh == true ? "Start a new household?" : "Restore household data?",
                            isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { preview in
            Button(preview.startsFresh ? "Start new household" : "Restore", role: .destructive) {
                do {
                    guard household.snapshot == preview.before else {
                        status = "Household data changed. Import the file again to review your changes."
                        return
                    }
                    try restore(preview.after)
                    status = preview.startsFresh ? "New household created." : "Household data restored."
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: { preview in
            Text(preview.startsFresh
                 ? "Create an empty household and keep a separate copy of the damaged file."
                 : "Replace the household information included in this file.")
        }
        .alert("Household file error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func beginExport(_ kind: ExportKind) {
        do {
            let bytes: Data
            switch kind {
            case .backup: bytes = try HouseholdBackup.encode(household.snapshot)
            case .notes: bytes = try DesktopHouseholdFiles.encodeNotes(household.snapshot)
            case .places: bytes = try DesktopHouseholdFiles.encodePlaces(household.snapshot)
            }
            exportKind = kind
            document = ExportDocument(bytes: bytes)
            exporting = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareImport(_ result: Result<URL, Error>) async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        status = nil
        do {
            let file = try result.get()
            let current = household.snapshot
            let isText = ["txt", "text"].contains(file.pathExtension.lowercased())
            let restored = try await Task.detached(priority: .userInitiated) {
                let bytes = try Self.read(file, asText: isText)
                return try HouseholdBackup.importing(bytes, asText: isText, into: current)
            }.value
            if household.snapshot != current {
                status = "Household data changed while reading the file. Import the file again."
            } else if household.loadError == nil, restored == current {
                status = "This file matches your household data."
            } else {
                pending = ImportPreview(before: current, after: restored)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private nonisolated static func read(_ file: URL, asText: Bool) throws -> Data {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: file, options: .withoutChanges, error: &coordinationError) { source in
            result = Result {
                let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard properties.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                let maximum = asText ? HouseholdBackup.Kind.desktopNotes.maximumBytes : 64 * 1024 * 1024
                guard let size = properties.fileSize, size <= maximum else {
                    throw CocoaError(.fileReadTooLarge)
                }
                return try Data(contentsOf: source, options: .mappedIfSafe)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private struct ImportPreview {
        let before: HouseholdSnapshot
        let after: HouseholdSnapshot
        var startsFresh = false
    }

    private enum ExportKind {
        case backup, notes, places

        var contentType: UTType { self == .notes ? .plainText : .json }

        var filename: String {
            switch self {
            case .backup: "Tinfoil-Kit-Household"
            case .notes: "notes"
            case .places: "places"
            }
        }
    }

    private struct ExportDocument: FileDocument {
        static let readableContentTypes: [UTType] = [.json, .plainText]
        let bytes: Data

        init(bytes: Data) { self.bytes = bytes }

        init(configuration: ReadConfiguration) throws {
            guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            bytes = data
        }

        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            FileWrapper(regularFileWithContents: bytes)
        }
    }
}
