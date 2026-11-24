import Foundation

public struct PublishedPack: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    public let version: String
    public let source: URL
    public let sha256: String
    public let sizeEstimate: Int64
    public let attribution: String

    public init(
        id: String, title: String, version: String, source: URL, sha256: String,
        sizeEstimate: Int64, attribution: String
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.source = source
        self.sha256 = sha256
        self.sizeEstimate = sizeEstimate
        self.attribution = attribution
    }

    public var editionKey: String { "\(id)-\(version)" }
}
