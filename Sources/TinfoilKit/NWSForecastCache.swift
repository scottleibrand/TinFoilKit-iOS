import Foundation

struct NWSForecastCache: Sendable {
    struct Entry: Codable, Sendable {
        let endpoint: URL
        let snapshot: NWSForecastSnapshot
    }

    let directory: URL

    func read(_ kind: NWSForecastKind) -> Entry? {
        guard let entry = read(Entry.self, named: kind.rawValue), entry.snapshot.kind == kind else { return nil }
        return entry
    }

    func write(_ entry: Entry) throws {
        try write(entry, named: entry.snapshot.kind.rawValue)
    }

    func readPoint() -> NWSForecastPoint? { read(NWSForecastPoint.self, named: "point") }

    func writePoint(_ point: NWSForecastPoint) throws { try write(point, named: "point") }

    private func read<Value: Decodable>(_ type: Value.Type, named name: String) -> Value? {
        guard let data = try? Data(contentsOf: file(named: name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<Value: Encodable>(_ value: Value, named name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        var folder = directory
        var settings = URLResourceValues()
        settings.isExcludedFromBackup = true
        try folder.setResourceValues(settings)
        #endif
        try JSONEncoder().encode(value).write(to: file(named: name), options: .atomic)
    }

    private func file(named name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension("json")
    }
}
