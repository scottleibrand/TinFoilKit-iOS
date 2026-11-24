import Combine
import Foundation
import UserNotifications

@MainActor
final class NearbyResumeNotifications: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var authorizationUnavailable = false

    private static let preferenceKey = "nearbyResumeNotificationsEnabled"
    private static let lastRequestKey = "nearbyResumeNotificationLastRequest"
    private static let requestID = "org.tinfoilkit.nearby-public-resume"
    private static let minimumInterval: TimeInterval = 30 * 60
    private let defaults: UserDefaults
    private let center = UNUserNotificationCenter.current()
    private var preferenceChange = UUID()
    private var clearRevision = UUID()
    private var isScheduling = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.preferenceKey)
    }

    /// Call from the explicit notification setting, where the system may ask for permission.
    func setEnabled(_ enabled: Bool) async {
        let change = UUID()
        preferenceChange = change
        authorizationUnavailable = false
        if enabled {
            let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
            guard preferenceChange == change else { return }
            isEnabled = granted
            authorizationUnavailable = !granted
        } else {
            isEnabled = false
        }
        defaults.set(isEnabled, forKey: Self.preferenceKey)
        if !isEnabled { clear() }
    }

    /// Enqueue immediately while the caller still has background execution time.
    func notifyInterruptedReceive() {
        guard isEnabled, !isScheduling else { return }
        let now = Date()
        let lastRequest = defaults.object(forKey: Self.lastRequestKey) as? Date
        if let lastRequest, (0..<Self.minimumInterval).contains(now.timeIntervalSince(lastRequest)) {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Nearby sync paused"
        content.body = "Open Tinfoil Kit to resume syncing public references."
        let request = UNNotificationRequest(identifier: Self.requestID, content: content, trigger: nil)
        let revision = clearRevision
        isScheduling = true
        defaults.set(now, forKey: Self.lastRequestKey)
        center.add(request) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScheduling = false
                if error != nil { self.defaults.set(lastRequest, forKey: Self.lastRequestKey) }
                if self.clearRevision != revision { self.removeAlert() }
            }
        }
    }

    func clear() {
        clearRevision = UUID()
        removeAlert()
    }

    private func removeAlert() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestID])
    }
}
