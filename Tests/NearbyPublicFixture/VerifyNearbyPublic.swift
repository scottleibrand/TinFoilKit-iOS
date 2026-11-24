import Foundation

@main
struct VerifyNearbyPublic {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { throw FixtureError.invalidArguments }
        let mode = arguments[1]
        let reference = NearbyPublicReference(
            directory: URL(fileURLWithPath: arguments[2]),
            bundledFile: arguments[3] == "-" ? nil : URL(fileURLWithPath: arguments[3]),
            availableCapacity: { _ in 100_000_000 }
        )
        let discovery = NearbyDiscovery(publicReference: reference)
        discovery.start(publicSync: mode != "disabled")
        defer { discovery.stop() }

        switch mode {
        case "serve":
            guard reference.loadVerified() != nil else { throw FixtureError.missingReference }
            try await Task.sleep(for: .seconds(50))
        case "receive", "disabled":
            let deadline = ContinuousClock.now + .seconds(mode == "receive" ? 18 : 5)
            while ContinuousClock.now < deadline {
                if discovery.publicReferenceText != nil {
                    guard mode == "receive", reference.loadVerified() != nil else {
                        throw FixtureError.unexpectedTransfer
                    }
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
