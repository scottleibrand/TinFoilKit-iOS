import Foundation

struct RegionalUpdateConnection: Equatable, Sendable {
    let online: Bool
    let metered: Bool

    func allowsRefresh(allowMetered: Bool) -> Bool {
        online && (allowMetered || !metered)
    }
}

struct RegionalRefreshThrottle {
    private var lastAttempt: ContinuousClock.Instant?
    private var succeeded = false

    mutating func begin(after interval: Duration, at now: ContinuousClock.Instant = .now) -> Bool {
        if let lastAttempt, now - lastAttempt < interval { return false }
        lastAttempt = now
        succeeded = false
        return true
    }

    mutating func finishSuccessfully() {
        succeeded = true
    }

    mutating func connectionInterrupted() {
        if !succeeded { lastAttempt = nil }
    }
}
