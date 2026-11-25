import Foundation
import PDFKit
import ZIMArchive

enum OfflineReadinessLibraryChecks {
    private struct Sample: Sendable {
        let archive: InstalledArchive
        let file: URL

        var title: String { String(archive.title.prefix(80)) }
    }

    private static let archiveLimit = 6
    private static let pdfEntryLimit: UInt32 = 2_048

    static func reference(in archives: [InstalledArchive]) async -> OfflineReadinessCheckResult {
        guard !archives.isEmpty else { return .unavailable("Install a library archive first.") }
        let pdfIDs = pdfPackIDs
        let candidates = archives.filter { !pdfIDs.contains($0.pack?.id ?? "") }
        let samples = await sample(Array(candidates.prefix(archiveLimit)))
        return await inspect {
            var couldNotRead = false
            for item in samples {
                try Task.checkCancellation()
                guard let resource = try? ZIMArchive(fileURL: item.file).mainArticle() else {
                    couldNotRead = true
                    continue
                }
                if isReadableHTML(resource) {
                    return .passed("Opened a local article from \(item.title).")
                }
            }
            return couldNotRead
                ? .failed("Couldn't open a start page in the sampled archives.")
                : .unavailable("No sampled archive has an HTML start page.")
        }
    }

    static func pdf(in archives: [InstalledArchive]) async -> OfflineReadinessCheckResult {
        guard !archives.isEmpty else { return .unavailable("Install a library archive first.") }
        let pdfIDs = pdfPackIDs
        let preferred = archives.filter { pdfIDs.contains($0.pack?.id ?? "") }
        let others = archives.filter { !pdfIDs.contains($0.pack?.id ?? "") }
        let samples = await sample(Array((preferred + others).prefix(archiveLimit)))
        return await inspect {
            var couldNotRead = false
            for item in samples {
                try Task.checkCancellation()
                guard let archive = try? ZIMArchive(fileURL: item.file) else {
                    couldNotRead = true
                    continue
                }
                guard let entries = try? archive.pdfEntries(inspectingFirst: pdfEntryLimit) else {
                    try Task.checkCancellation()
                    couldNotRead = true
                    continue
                }
                for entry in entries.prefix(2) {
                    try Task.checkCancellation()
                    if let resource = try? archive.resource(at: entry.path), isReadablePDF(resource, pageIndex: 0) {
                        return .passed("Opened a local PDF page from \(item.title).")
                    }
                    couldNotRead = true
                }
            }
            return couldNotRead
                ? .failed("Couldn't open a PDF in the sampled archives.")
                : .unavailable("No PDF found among the sampled archive entries.")
        }
    }

    static func passages(query: String, in archives: [InstalledArchive]) async -> OfflineReadinessCheckResult {
        let query = String(query.prefix(500))
        guard !LibraryPassages.queries(for: query, suggested: []).isEmpty else {
            return .unavailable("Enter a topic from an installed reference.")
        }
        guard !archives.isEmpty else { return .unavailable("Install a library archive first.") }
        let samples = await sample(archives)
        let indexed = samples.filter { ArticleIndex(archiveURL: $0.file).hasSearchableIndex }.map(\.archive)
        guard !Task.isCancelled else { return .unavailable("The library check was cancelled.") }
        guard !indexed.isEmpty else { return .unavailable("No installed archive has a search index yet.") }

        do {
            let result = try await LibraryPassages.search(question: query, archives: indexed, library: .standard)
            if result.sources.isEmpty {
                return result.unreadableArchives > 0
                    ? .failed("Couldn't read all installed search indexes.")
                    : .unavailable("No local passages matched in the installed indexes.")
            }
            return await inspect {
                for source in result.sources.prefix(3) {
                    try Task.checkCancellation()
                    guard let item = samples.first(where: { $0.archive.id == source.archive.id }),
                          let archive = try? ZIMArchive(fileURL: item.file) else { continue }
                    let pdf = ArchivePDFReference(articlePath: source.match.path)
                    guard let resource = try? archive.resource(at: pdf?.path ?? source.match.path) else { continue }
                    let readable = pdf.map { isReadablePDF(resource, pageIndex: $0.pageIndex) }
                        ?? isReadableHTML(resource)
                    if readable {
                        return .passed("Found a local passage and opened its source in \(item.title).")
                    }
                }
                return .failed("Found passages, but couldn't open their sampled sources.")
            }
        } catch is CancellationError {
            return .unavailable("The library check was cancelled.")
        } catch {
            return .failed("Couldn't search the installed library.")
        }
    }

    private static var pdfPackIDs: Set<String> {
        Set(PackCatalog.entries.filter(\.usesPDFDirectory).map(\.pack.id))
    }

    private static func sample(_ archives: [InstalledArchive]) async -> [Sample] {
        var samples: [Sample] = []
        for archive in archives {
            if Task.isCancelled { break }
            let file = await InstalledLibrary.standard.fileURL(for: archive.id)
            samples.append(Sample(archive: archive, file: file))
        }
        return samples
    }

    private static func inspect(
        _ operation: @escaping @Sendable () throws -> OfflineReadinessCheckResult
    ) async -> OfflineReadinessCheckResult {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try operation()
        }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch is CancellationError {
            return .unavailable("The library check was cancelled.")
        } catch {
            return .failed("Couldn't read the sampled library archives.")
        }
    }

    private static func isReadableHTML(_ resource: ZIMArchive.Resource) -> Bool {
        resource.mimeType.hasPrefix("text/html") && !resource.path.isEmpty && !resource.data.isEmpty
    }

    private static func isReadablePDF(_ resource: ZIMArchive.Resource, pageIndex: Int) -> Bool {
        guard resource.mimeType == "application/pdf", let document = PDFDocument(data: resource.data),
              !document.isLocked, pageIndex < document.pageCount else { return false }
        return document.page(at: pageIndex) != nil
    }
}
