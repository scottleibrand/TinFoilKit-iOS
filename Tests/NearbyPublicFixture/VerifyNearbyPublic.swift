import Foundation

@main
struct VerifyNearbyPublic {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 || arguments.count == 5 else { throw FixtureError.invalidArguments }
        let mode = arguments[1]
        let reference = NearbyPublicReference(
            directory: URL(fileURLWithPath: arguments[2]),
            bundledFile: arguments[3] == "-" ? nil : URL(fileURLWithPath: arguments[3]),
            availableCapacity: { _ in 100_000_000 }
        )
        if mode == "receive-checkpoint" {
            guard arguments.count == 5 else { throw FixtureError.invalidArguments }
            let seed = try Data(contentsOf: URL(fileURLWithPath: arguments[4]))
            let prefix = Data(seed.prefix(512))
            try reference.saveCheckpoint(prefix)
            guard reference.checkpoint() == prefix else { throw FixtureError.unexpectedTransfer }
        }
        let discovery = NearbyDiscovery(publicReference: reference)
        let draining = mode.hasSuffix("-draining")
        var stoppedDiscoveryForTransfer = false
        if draining {
            discovery.activityDidChange = { [weak discovery] active in
                guard active, let discovery else { return }
                precondition(discovery.hasActivePublicReceive == (mode == "receive-draining"))
                discovery.finishTransfersWithoutDiscovery()
                stoppedDiscoveryForTransfer = !discovery.isRunning
            }
        }
        discovery.start(publicSync: mode != "disabled")
        defer { discovery.stop() }

        switch mode {
        case "serve", "serve-draining":
            guard reference.loadVerified() != nil else { throw FixtureError.missingReference }
            try await Task.sleep(for: .seconds(50))
        case "receive", "receive-draining", "receive-checkpoint", "disabled":
            let deadline = ContinuousClock.now + .seconds(mode == "disabled" ? 5 : 26)
            while ContinuousClock.now < deadline {
                if discovery.publicReferenceText != nil {
                    guard mode != "disabled", reference.loadVerified() != nil,
                          !draining || stoppedDiscoveryForTransfer,
                          mode != "receive-checkpoint" || reference.checkpoint().isEmpty else {
                        throw FixtureError.unexpectedTransfer
                    }
                    if draining { print("Verified receipt after Nearby discovery stopped.") }
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard mode == "disabled", !discovery.peers.isEmpty else {
                FileHandle.standardError.write(Data("Nearby fixture mode \(mode), state \(discovery.state), peers \(discovery.peers.count)\n".utf8))
                throw FixtureError.discoveryOrTransferFailed
            }
        default:
            throw FixtureError.invalidArguments
        }
    }

    private enum FixtureError: Error {
        case invalidArguments, missingReference, unexpectedTransfer, discoveryOrTransferFailed
    }
}
