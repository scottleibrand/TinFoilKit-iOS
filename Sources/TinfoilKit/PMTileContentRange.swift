import Foundation

/// Validates a partial response against the exact range requested from a PMTiles archive.
struct PMTileContentRange {
    let archiveLength: UInt64?

    init?(_ header: String?, start: UInt64, end: UInt64) {
        guard start <= end, let header else { return nil }
        let prefix = "bytes \(start)-\(end)/"
        guard header.hasPrefix(prefix) else { return nil }
        let total = header.dropFirst(prefix.count)
        if total == "*" {
            archiveLength = nil
        } else {
            guard !total.isEmpty, total.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = UInt64(total), length > end else { return nil }
            archiveLength = length
        }
    }
}
