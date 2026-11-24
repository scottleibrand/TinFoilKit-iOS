import Foundation

struct RegionalBundleManifest: Codable, Equatable, Sendable {
    struct Asset: Codable, Equatable, Sendable {
        let filename: String
        let url: URL
        let byteCount: Int64
        let sha256: String

        func validateFile(at file: URL) throws {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            guard file.isFileURL, let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink == false,
                  values.fileSize.map(Int64.init) == byteCount else {
                throw Error.invalidArtifact(filename)
            }
        }
    }

    struct Assets: Codable, Equatable, Sendable {
        let places: Asset
        let routing: Asset
    }

    enum Error: LocalizedError, Equatable {
        case invalidManifest
        case invalidArtifact(String)
        case metadataMismatch(String)

        var errorDescription: String? {
            switch self {
            case .invalidManifest:
                "The folder needs a valid Tinfoil Kit regional bundle manifest."
            case .invalidArtifact(let name):
                "The regional bundle file \(name) is missing, damaged, or does not match its manifest."
            case .metadataMismatch(let name):
                "The dataset details in \(name) do not match the regional bundle manifest."
            }
        }
    }

    private static let maximumManifestBytes = 65_536

    let schemaVersion: Int
    let region: String
    let dataVersion: String
    let source: URL
    let sourceSHA256: String
    let bounds: RoutingPack.Bounds
    let artifactBaseURL: URL
    let attribution: String
    let license: String
    let licenseURL: URL
    let assets: Assets

    static func read(from file: URL) throws -> Self {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard file.isFileURL, let values = try? file.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isSymbolicLink == false,
              let size = values.fileSize, (1...maximumManifestBytes).contains(size),
              let input = try? FileHandle(forReadingFrom: file) else {
            throw Error.invalidManifest
        }
        defer { try? input.close() }
        guard let data = try input.read(upToCount: maximumManifestBytes + 1), data.count == size,
              let manifest = try? JSONDecoder().decode(Self.self, from: data) else {
            throw Error.invalidManifest
        }
        try manifest.validate()
        return manifest
    }

    func validate(places: RegionalPlaceIndex.Metadata) throws {
        guard let area = places.bounds,
              area.west == bounds.west, area.south == bounds.south,
              area.east == bounds.east, area.north == bounds.north,
              places.region == region, places.dataVersion == dataVersion, places.source == source,
              places.attribution == attribution, places.license == license, places.licenseURL == licenseURL else {
            throw Error.metadataMismatch(assets.places.filename)
        }
    }

    func validate(routing: RoutingPack) throws {
        try routing.validate()
        guard routing.bounds == bounds, routing.sourceSHA256 == sourceSHA256,
              routing.region == region, routing.dataVersion == dataVersion, routing.source == source,
              routing.attribution == attribution, routing.license == license, routing.licenseURL == licenseURL else {
            throw Error.metadataMismatch(assets.routing.filename)
        }
    }

    private func validate() throws {
        guard schemaVersion == 1, !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              region.unicodeScalars.count <= 120, !dataVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bounds.isValid, !(bounds.west == 180 && bounds.east == -180),
              Self.isHTTPS(source), Self.isHTTPS(artifactBaseURL), artifactBaseURL.query == nil,
              Self.isSHA256(sourceSHA256), attribution == "© OpenStreetMap contributors",
              license == "ODbL-1.0", licenseURL.absoluteString == "https://www.openstreetmap.org/copyright",
              !assets.places.byteCount.addingReportingOverflow(assets.routing.byteCount).overflow else {
            throw Error.invalidManifest
        }
        try validate(assets.places, filename: "places.sqlite")
        try validate(assets.routing, filename: "routing.tfkroute")
    }

    private func validate(_ asset: Asset, filename: String) throws {
        let base = artifactBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard asset.filename == filename, asset.byteCount > 0, Self.isSHA256(asset.sha256),
              Self.isHTTPS(asset.url), asset.url.absoluteString == "\(base)/\(filename)" else {
            throw Error.invalidArtifact(filename)
        }
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.isEmpty == false
            && url.user == nil && url.password == nil && url.fragment == nil
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
