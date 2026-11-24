import Foundation

/// Fixed-width offset for the catalog-pinned worksheet on the version 2 connection.
enum NearbyPublicResume {
    static let requestLength = 4

    static func request(offset: Int) -> Data {
        var encoded = UInt32(offset).bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }

    static func offset(from request: Data, byteCount: Int) -> Int? {
        guard request.count == requestLength else { return nil }
        let offset = request.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let value = Int(exactly: offset), value < byteCount else { return nil }
        return value
    }

    static func load(from file: URL, byteCount: Int) -> Data {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1..<byteCount).contains(size),
              let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: size + 1), data.count == size else { return Data() }
        return data
    }
}
