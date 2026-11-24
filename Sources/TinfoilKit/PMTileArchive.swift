import Foundation
import zlib

struct MapTile: Hashable, Sendable {
    let zoom: Int
    let x: Int
    let y: Int

    // PMTiles v3 numbers tiles by zoom and then by Hilbert curve order.
    var id: UInt64 {
        var x = x
        var y = y
        var order: UInt64 = 0
        var bit = (1 << zoom) >> 1
        while bit > 0 {
            let east = x & bit == 0 ? 0 : 1
            let south = y & bit == 0 ? 0 : 1
            order += UInt64(bit * bit * ((3 * east) ^ south))
            if south == 0 {
                if east != 0 {
                    x ^= bit - 1
                    y ^= bit - 1
                }
                swap(&x, &y)
            }
            bit >>= 1
        }
        return ((UInt64(1) << (2 * zoom)) - 1) / 3 + order
    }

    func parent(at zoom: Int) -> MapTile {
        MapTile(zoom: zoom, x: x >> (self.zoom - zoom), y: y >> (self.zoom - zoom))
    }
}

/// Reads bounded ranges from a single PMTiles v3 MVT archive.
actor PMTileArchive {
    private let url: URL
    private var snapshot: Task<Snapshot, Error>?
    private var leaves: [UInt64: Task<[Entry], Error>] = [:]
    private var etag: String?
    private let session: URLSession
    private static let cellularSession = makeSession(allowsCellular: true)
    private static let nonCellularSession = makeSession(allowsCellular: false)

    private static func makeSession(allowsCellular: Bool) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.allowsCellularAccess = allowsCellular
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = ["User-Agent": "TinfoilKit-iOS/1"]
        return URLSession(configuration: config)
    }

    init(url: URL, allowsCellular: Bool = true) {
        self.url = url
        session = allowsCellular ? Self.cellularSession : Self.nonCellularSession
    }

    func contains(_ tile: MapTile) async throws -> Bool {
        try await locate(tile, allowOverzoom: true) != nil
    }

    func cancelPendingReads() {
        snapshot?.cancel()
        snapshot = nil
        for leaf in leaves.values { leaf.cancel() }
        leaves.removeAll()
    }

    func vectorTile(_ tile: MapTile) async throws -> Data? {
        guard let (entry, snapshot) = try await locate(tile, allowOverzoom: false) else { return nil }
        let offset = try snapshot.tiles.address(of: entry)
        do {
            let compressed = try await read(offset: offset, count: entry.length)
            return try Self.decode(compressed, compression: snapshot.tileCompression)
        } catch ArchiveError.changed {
            self.snapshot = nil
            leaves.removeAll()
            etag = nil
            throw ArchiveError.changed
        }
    }

    private func locate(_ tile: MapTile, allowOverzoom: Bool) async throws -> (Entry, Snapshot)? {
        do {
            let index = try await loadSnapshot()
            guard tile.zoom >= index.minZoom, allowOverzoom || tile.zoom <= index.maxZoom else { return nil }
            let id = tile.parent(at: min(tile.zoom, index.maxZoom)).id
            var directory = index.root
            for _ in 0..<4 {
                guard let entry = Self.find(id, in: directory) else { return nil }
                if entry.run > 0 { return (entry, index) }
                let offset = try index.leaves.address(of: entry)
                if leaves[offset] == nil {
                    if leaves.count >= 64 { leaves.removeAll() }
                    leaves[offset] = Task {
                        let bytes = try await self.read(offset: offset, count: entry.length)
                        return try Self.entries(in: Self.decode(bytes, compression: index.directoryCompression))
                    }
                }
                guard let leaf = leaves[offset] else { throw ArchiveError.invalid }
                do {
                    directory = try await leaf.value
                } catch {
                    leaves[offset] = nil
                    throw error
                }
            }
            throw ArchiveError.invalid
        } catch ArchiveError.changed {
            snapshot = nil
            leaves.removeAll()
            etag = nil
            throw ArchiveError.changed
        }
    }

    private func loadSnapshot() async throws -> Snapshot {
        if let snapshot { return try await snapshot.value }
        let task = Task {
            let header = try await self.read(offset: 0, count: 127)
            guard header.prefix(7) == Data("PMTiles".utf8), header[7] == 3, header[99] == 1,
                  header[100] <= header[101], header[101] <= 30 else { throw ArchiveError.invalid }
            func integer(_ offset: Int) -> UInt64 {
                header.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
            }
            let rootOffset = integer(8)
            let rootLength = integer(16)
            guard rootOffset >= 127, rootOffset <= 16_384,
                  rootLength > 0, rootLength <= 16_384 - rootOffset else { throw ArchiveError.invalid }
            let root = try await self.read(offset: rootOffset, count: Int(rootLength))
            return Snapshot(
                root: try Self.entries(in: Self.decode(root, compression: header[97])),
                leaves: Section(offset: integer(40), length: integer(48)),
                tiles: Section(offset: integer(56), length: integer(64)),
                directoryCompression: header[97], tileCompression: header[98],
                minZoom: Int(header[100]), maxZoom: Int(header[101])
            )
        }
        snapshot = task
        do {
            return try await task.value
        } catch {
            snapshot = nil
            throw error
        }
    }

    private func read(offset: UInt64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard count > 0, count <= 2 * 1024 * 1024 else { throw ArchiveError.invalid }
        let end = try Self.add(offset, UInt64(count - 1))
        if url.isFileURL {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            try file.seek(toOffset: offset)
            guard let bytes = try file.read(upToCount: count), bytes.count == count else { throw ArchiveError.invalid }
            return bytes
        }

        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        let (body, reply) = try await session.bytes(for: request)
        guard let response = reply as? HTTPURLResponse else { throw ArchiveError.invalid }
        if response.statusCode == 412 { throw ArchiveError.changed }
        guard response.statusCode == 206,
              response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(offset)-\(end)/") == true else {
            throw ArchiveError.invalid
        }
        if let current = response.value(forHTTPHeaderField: "ETag") {
            if let etag, etag != current { throw ArchiveError.changed }
            etag = current
        }
        var data = Data(capacity: count)
        for try await byte in body {
            guard data.count < count else { throw ArchiveError.invalid }
            data.append(byte)
        }
        guard data.count == count else { throw ArchiveError.invalid }
        return data
    }

    private static func find(_ id: UInt64, in entries: [Entry]) -> Entry? {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let mid = lower + (upper - lower) / 2
            if entries[mid].id <= id { lower = mid + 1 } else { upper = mid }
        }
        guard lower > 0 else { return nil }
        let entry = entries[lower - 1]
        return entry.run == 0 || id - entry.id < entry.run ? entry : nil
    }

    private static func entries(in data: Data) throws -> [Entry] {
        var cursor = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard cursor < data.count else { throw ArchiveError.invalid }
                let byte = data[cursor]
                cursor += 1
                guard shift != 63 || byte <= 1 else { throw ArchiveError.invalid }
                result |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return result }
            }
            throw ArchiveError.invalid
        }
        let count = try varint()
        guard count > 0, count <= min(200_000, UInt64(data.count / 4)) else { throw ArchiveError.invalid }
        var entries = Array(repeating: Entry(), count: Int(count))
        var id: UInt64 = 0
        for index in entries.indices {
            let delta = try varint()
            guard index == 0 || delta > 0 else { throw ArchiveError.invalid }
            id = try add(id, delta)
            entries[index].id = id
        }
        for index in entries.indices { entries[index].run = try varint() }
        for index in entries.indices {
            let length = try varint()
            guard length > 0, let size = Int(exactly: length) else { throw ArchiveError.invalid }
            entries[index].length = size
        }
        for index in entries.indices {
            let offset = try varint()
            if offset == 0 {
                guard index > 0 else { throw ArchiveError.invalid }
                let prior = entries[index - 1]
                entries[index].offset = try add(prior.offset, UInt64(prior.length))
            } else {
                entries[index].offset = offset - 1
            }
        }
        return entries
    }

    private static func decode(_ bytes: Data, compression: UInt8) throws -> Data {
        if compression == 1 { return bytes }
        guard compression == 2 else { throw ArchiveError.invalid }
        return try bytes.withUnsafeBytes { input in
            var stream = z_stream()
            guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw ArchiveError.invalid
            }
            defer { inflateEnd(&stream) }
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(input.count)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            var status: Int32
            repeat {
                let capacity = buffer.count
                status = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = UInt32(capacity)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw ArchiveError.invalid }
                let count = capacity - Int(stream.avail_out)
                guard result.count + count <= 16 * 1024 * 1024 else { throw ArchiveError.invalid }
                result.append(contentsOf: buffer.prefix(count))
            } while status != Z_STREAM_END
            return result
        }
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw ArchiveError.invalid }
        return result
    }

    private struct Snapshot {
        let root: [Entry]
        let leaves: Section
        let tiles: Section
        let directoryCompression: UInt8
        let tileCompression: UInt8
        let minZoom: Int
        let maxZoom: Int
    }

    private struct Section {
        let offset: UInt64
        let length: UInt64

        func address(of entry: Entry) throws -> UInt64 {
            guard try PMTileArchive.add(entry.offset, UInt64(entry.length)) <= length else { throw ArchiveError.invalid }
            return try PMTileArchive.add(offset, entry.offset)
        }
    }

    private struct Entry {
        var id: UInt64 = 0
        var run: UInt64 = 0
        var length = 0
        var offset: UInt64 = 0
    }

    private enum ArchiveError: Error { case invalid, changed }
}
