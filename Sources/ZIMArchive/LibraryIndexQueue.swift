import Foundation

enum LibraryIndexQueue {
    static func next(in archives: [InstalledArchive], excluding unavailable: Set<UUID>) -> InstalledArchive? {
        archives.lazy.filter { !unavailable.contains($0.id) }.min { $0.byteCount < $1.byteCount }
    }

    static func shouldPreempt(_ active: InstalledArchive, for next: InstalledArchive?) -> Bool {
        guard let next else { return false }
        return next.byteCount < active.byteCount
    }
}
