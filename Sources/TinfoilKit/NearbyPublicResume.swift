import Foundation

/// The catalog pin and fixed-width offset on the version 2 connection.
enum NearbyPublicResume {
    static func requestLength(pin: String) -> Int { pin.utf8.count + 4 }

    static func request(pin: String, offset: Int) -> Data {
        var encoded = UInt32(offset).bigEndian
        return Data(pin.utf8) + withUnsafeBytes(of: &encoded) { Data($0) }
    }

    static func offset(from request: Data, pin: String, byteCount: Int) -> Int? {
        let prefix = Data(pin.utf8)
        guard request.count == requestLength(pin: pin), request.starts(with: prefix) else { return nil }
        let offset = request.dropFirst(prefix.count).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
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

/// Version 3 uses a fixed SHA-256 pin and the same bounded resume offset.
enum NearbyPublicCatalogRequest {
    static let byteCount = 64 + 4

    static func request(for manifest: NearbyPublicManifest, offset: Int) -> Data {
        NearbyPublicResume.request(pin: manifest.sha256, offset: offset)
    }

    static func match(_ request: Data, in catalog: [NearbyPublicManifest]) -> (id: String, offset: Int)? {
        guard request.count == byteCount else { return nil }
        for manifest in catalog {
            if let offset = NearbyPublicResume.offset(from: request, pin: manifest.sha256, byteCount: manifest.byteCount) {
                return (manifest.id, offset)
            }
        }
        return nil
    }
}
