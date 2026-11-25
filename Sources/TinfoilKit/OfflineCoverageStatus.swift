enum OfflineCoverageStatus: Equatable {
    case inside, outside, unknown

    init(candidates: [Bool?]) {
        if candidates.contains(true) { self = .inside }
        else if candidates.contains(nil) { self = .unknown }
        else { self = .outside }
    }

    var title: String {
        switch self {
        case .inside: "Inside coverage"
        case .outside: "Outside coverage"
        case .unknown: "Coverage unknown"
        }
    }
}
