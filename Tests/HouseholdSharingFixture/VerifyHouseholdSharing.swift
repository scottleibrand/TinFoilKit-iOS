import Foundation

@main
enum VerifyHouseholdSharing {
    static func main() async throws {
        let home = HouseholdPlace(name: "Home <north>", latitude: 47.6, longitude: -122.3)
        let page = HouseholdSharePage(snapshot: HouseholdSnapshot(notes: "Meet by A & B\n<gate>", home: home))
        let loopback = HouseholdShareAddress(interface: "lo0", host: "127.0.0.1", address: 0x7f000001, mask: UInt32.max)

        let (events, emitter) = AsyncStream<HouseholdShareServer.Event>.makeStream()
        let server = try HouseholdShareServer(address: loopback, page: page, lifetime: 4) { event in
            emitter.yield(event)
        }
        var iterator = events.makeAsyncIterator()
        server.start()

        let event = await iterator.next()
        guard case let .listening(link) = event else {
            fatalError("Listener did not start: \(String(describing: event))")
        }
        defer { server.stop() }
        let browser = URLSession(configuration: .ephemeral)
        defer { browser.invalidateAndCancel() }

        let unshared = link.deletingLastPathComponent().appendingPathComponent("different-link")
        let (invalidBody, invalidResponse) = try await browser.data(from: unshared)
        precondition((invalidResponse as? HTTPURLResponse)?.statusCode == 404)
        precondition(!String(decoding: invalidBody, as: UTF8.self).contains("Meet"))

        var mutation = URLRequest(url: link)
        mutation.httpMethod = "POST"
        let (_, mutationResponse) = try await browser.data(for: mutation)
        precondition((mutationResponse as? HTTPURLResponse)?.statusCode == 404)

        let (body, response) = try await browser.data(from: link)
        let received = String(decoding: body, as: UTF8.self)
        let http = response as? HTTPURLResponse
        precondition(http?.statusCode == 200)
        precondition(received.contains("Meet by A &amp; B\n&lt;gate&gt;"))
        precondition(received.contains("Home &lt;north&gt;"))
        precondition(!received.contains("<h2>Pins</h2>"))
        precondition(http?.value(forHTTPHeaderField: "Cache-Control") == "no-store")

        guard case .expired = await iterator.next() else { fatalError("Unconfirmed expiry") }
        do {
            _ = try await browser.data(from: link)
            fatalError("An expired link still worked")
        } catch is URLError {}

        let (newEvents, newEmitter) = AsyncStream<HouseholdShareServer.Event>.makeStream()
        let stoppable = try HouseholdShareServer(address: loopback, page: page, lifetime: 60) { event in
            newEmitter.yield(event)
        }
        var newIterator = newEvents.makeAsyncIterator()
        stoppable.start()
        guard case let .listening(newLink) = await newIterator.next() else { fatalError("Could not restart sharing") }
        precondition(newLink.lastPathComponent != link.lastPathComponent)
        let (_, activeResponse) = try await browser.data(from: newLink)
        precondition((activeResponse as? HTTPURLResponse)?.statusCode == 200)
        stoppable.stop()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            do {
                let request = URLRequest(url: newLink, timeoutInterval: 0.5)
                _ = try await browser.data(for: request)
                try await Task.sleep(for: .milliseconds(50))
            } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                print("Verified private household viewing, withheld fields, read-only requests, expiry, and manual stop.")
                return
            }
        }
        fatalError("An explicitly stopped link still worked")
    }
}
