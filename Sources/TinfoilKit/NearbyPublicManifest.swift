import Foundation

/// A public reference pinned by the app's catalog, independent of the transport.
struct NearbyPublicManifest: Equatable, Sendable {
    let id: String
    let byteCount: Int
    let sha256: String

    init?(id: String, byteCount: Int, sha256: String) {
        guard !id.isEmpty, id.utf8.count <= 64, id.utf8.allSatisfy({
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }), byteCount > 0, sha256.utf8.count == 64, sha256.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { return nil }
        self.id = id
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    enum Admission: Equatable {
        case receive, unlisted, alreadyInstalled, insufficientStorage
    }

    func admit(_ offer: Self, verifiedDigests: Set<String>, availableBytes: Int64?) -> Admission {
        guard offer == self else { return .unlisted }
        guard !verifiedDigests.contains(sha256) else { return .alreadyInstalled }
        // Allow space for the staged write, its destination, and filesystem overhead.
        let overhead: Int64 = 1_048_576
        guard let availableBytes, availableBytes >= overhead,
              Int64(byteCount) <= (availableBytes - overhead) / 2 else { return .insufficientStorage }
        return .receive
    }
}
