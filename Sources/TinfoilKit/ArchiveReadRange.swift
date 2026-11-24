enum ArchiveReadRange: Equatable {
    case full
    case partial(Range<Int>)
    case unsatisfiable

    static func parse(_ header: String?, count: Int) -> Self {
        guard let header else { return .full }
        let fields = header.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { return .full }
        // Ignore unsupported multi-range and malformed fields, preserving ordinary reads.
        let ends = fields[1].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard ends.count == 2, !ends.allSatisfy(\.isEmpty),
              ends.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return .full }
        guard count > 0 else { return .unsatisfiable }

        if ends[0].isEmpty {
            let length = Int(ends[1]) ?? Int.max
            guard length > 0 else { return .unsatisfiable }
            return .partial((count - min(length, count))..<count)
        }
        guard let lower = Int(ends[0]), lower < count else { return .unsatisfiable }
        let upper = ends[1].isEmpty ? count - 1 : min(Int(ends[1]) ?? Int.max, count - 1)
        guard upper >= lower else { return .unsatisfiable }
        return .partial(lower..<(upper + 1))
    }

    func contentRange(count: Int) -> String? {
        switch self {
        case .full: nil
        case .partial(let range): "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(count)"
        case .unsatisfiable: "bytes */\(count)"
        }
    }
}
