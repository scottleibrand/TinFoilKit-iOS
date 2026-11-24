import Foundation

enum StagingCleanup {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var activeNames: Set<String> = []
    }

    private static let state = State()

    static func beginImport(in directory: URL, includingLegacyUUIDFiles: Bool = false) -> URL {
        let folder = directory.resolvingSymlinksInPath()
        let staging = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("partial")
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]

        // Separate storage actors can use the same directory. Register the UUID
        // filename under the scan lock before writing, regardless of directory aliases.
        state.lock.withLock {
            let files = FileManager.default
            let entries = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
            for entry in entries where !state.activeNames.contains(entry.lastPathComponent) {
                let name = entry.pathExtension == "partial"
                    ? entry.deletingPathExtension().lastPathComponent : entry.lastPathComponent
                guard entry.pathExtension == "partial" || includingLegacyUUIDFiles,
                      UUID(uuidString: name) != nil,
                      let values = try? entry.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                try? files.removeItem(at: entry)
            }
            state.activeNames.insert(staging.lastPathComponent)
        }
        return staging
    }

    static func endImport(at staging: URL) {
        state.lock.withLock {
            guard state.activeNames.remove(staging.lastPathComponent) != nil else { return }
            try? FileManager.default.removeItem(at: staging)
        }
    }
}
