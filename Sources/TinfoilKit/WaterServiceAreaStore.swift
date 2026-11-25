import CryptoKit
import Foundation

actor WaterServiceAreaStore {
    static let standard = WaterServiceAreaStore(
        directory: URL.applicationSupportDirectory.appendingPathComponent("WaterServiceAreas", isDirectory: true)
    )
    static let edition = "2026-11-23"
    static let source = URL(string: "https://geo.wa.gov/datasets/WADOH%3A%3Adrinking-water-service-areas/about")!
    private static let editionSHA256 = "8dc74d57d50cddf03f0ddb4d1bcc58889f6ab548657dcab4856bd2851f5193d1"

    private let directory: URL
    private let expectedSHA256: String
    private let file: URL
    private var installed: WaterServiceAreas?

    init(directory: URL, expectedSHA256: String? = nil) {
        self.directory = directory
        self.expectedSHA256 = expectedSHA256 ?? Self.editionSHA256
        file = directory.appendingPathComponent("seattle-water-service-areas.geojson")
    }

    func isInstalled() -> Bool {
        (try? load()) != nil
    }

    func install(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try read(url)
        let areas = try verified(data)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var settings = URLResourceValues()
        settings.isExcludedFromBackup = true
        var folder = directory
        try folder.setResourceValues(settings)
        try data.write(to: file, options: .atomic)
        installed = areas
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        installed = nil
    }

    func providers(latitude: Double, longitude: Double) throws -> [WaterServiceProvider] {
        try load().providers(latitude: latitude, longitude: longitude)
    }

    private func load() throws -> WaterServiceAreas {
        if let installed { return installed }
        guard FileManager.default.fileExists(atPath: file.path) else { throw StoreError.notInstalled }
        let areas = try verified(read(file))
        installed = areas
        return areas
    }

    private func read(_ url: URL) throws -> Data {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw StoreError.invalidFile
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var bytes = Data()
        while let block = try input.read(upToCount: 64 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            guard block.count <= WaterServiceAreas.maxBytes - bytes.count else { throw StoreError.tooLarge }
            bytes.append(block)
        }
        return bytes
    }

    private func verified(_ data: Data) throws -> WaterServiceAreas {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else { throw StoreError.wrongEdition }
        return try WaterServiceAreas(data: data)
    }

    private enum StoreError: LocalizedError {
        case invalidFile, tooLarge, wrongEdition, notInstalled

        var errorDescription: String? {
            switch self {
            case .invalidFile: "Choose the Seattle water service areas file from Files."
            case .tooLarge: "The water service areas file exceeds the import size limit."
            case .wrongEdition: "This file does not match the verified Seattle water service area edition."
            case .notInstalled: "Import the Seattle water service areas to look up a mapped provider."
            }
        }
    }
}
