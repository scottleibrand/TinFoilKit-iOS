import SwiftUI
import UIKit

/// Keeps opt-in discovery alive across tabs and gives established public transfers time to finish.
@MainActor
final class NearbyLifecycle: ObservableObject {
    let discovery: NearbyDiscovery
    let notifications: NearbyResumeNotifications
    @Published private(set) var publicSyncEnabled: Bool

    private static let preferenceKey = "nearbyPublicSyncEnabled"
    private let defaults: UserDefaults
    private var phase: ScenePhase = .inactive
    private var nearbyScreens: Set<UUID> = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var assertionID: UUID?
    private var backgroundReceiveID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        publicSyncEnabled = defaults.bool(forKey: Self.preferenceKey)
        discovery = NearbyDiscovery()
        notifications = NearbyResumeNotifications(defaults: defaults)
        discovery.activityDidChange = { [weak self] active in self?.transferActivityChanged(active) }
    }

    func updatePhase(_ phase: ScenePhase) {
        guard phase != self.phase else { return }
        self.phase = phase
        if phase == .background {
            backgroundReceiveID = publicSyncEnabled ? discovery.activePublicReceiveReferenceID : nil
            if backgroundTask != .invalid, publicSyncEnabled, discovery.hasActivePublicTransfer {
                discovery.finishTransfersWithoutDiscovery()
            } else {
                notifyIfReceiveInterrupted()
                discovery.stop()
                endBackgroundTask()
            }
        } else {
            backgroundReceiveID = nil
            if phase == .active { notifications.clear() }
            updateDiscovery()
        }
    }

    func setNearbyScreen(_ id: UUID, visible: Bool) {
        if visible { nearbyScreens.insert(id) }
        else { nearbyScreens.remove(id) }
        updateDiscovery()
    }

    func setPublicSyncEnabled(_ enabled: Bool) {
        guard enabled != publicSyncEnabled else { return }
        publicSyncEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        if !enabled {
            backgroundReceiveID = nil
            notifications.clear()
            discovery.stop()
            endBackgroundTask()
        }
        updateDiscovery()
    }

    private func updateDiscovery() {
        guard phase != .background else { return }
        let shouldDiscover = publicSyncEnabled || !nearbyScreens.isEmpty
        if !shouldDiscover {
            discovery.stop()
        } else if phase == .active {
            discovery.start(publicSync: publicSyncEnabled)
        }
    }

    private func transferActivityChanged(_ active: Bool) {
        if active {
            if publicSyncEnabled, phase != .background { beginBackgroundTask() }
        } else {
            if phase == .background { notifyIfReceiveInterrupted() }
            endBackgroundTask()
            if phase == .background { discovery.stop() }
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        let id = UUID()
        assertionID = id
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish Nearby public transfer") { [weak self] in
            guard let self, self.assertionID == id else { return }
            if self.phase == .background { self.notifyIfReceiveInterrupted() }
            self.discovery.stop()
            self.endBackgroundTask()
            self.updateDiscovery()
        }
        if backgroundTask == .invalid { assertionID = nil }
    }

    private func notifyIfReceiveInterrupted() {
        guard let id = backgroundReceiveID else { return }
        backgroundReceiveID = nil
        if publicSyncEnabled, !discovery.publicReferences.contains(where: { $0.id == id }) {
            notifications.notifyInterruptedReceive()
        }
    }

    private func endBackgroundTask() {
        assertionID = nil
        guard backgroundTask != .invalid else { return }
        let ending = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(ending)
    }
}
