import Foundation

@main
enum VerifyHouseholdSharing {
    @MainActor static func main() async throws {
        let home = HouseholdPlace(name: "Home <north>", latitude: 47.6, longitude: -122.3)
        let page = HouseholdSharePage(snapshot: HouseholdSnapshot(notes: "Meet by A & B\n<gate>", home: home))
        let publicReferences = try verifyPublicReferences()
        let publicPage = HouseholdSharePage(snapshot: HouseholdSnapshot(), publicReferences: publicReferences,
                                            acceptsNotes: true)
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

        let mutation = noteRequest("note=Being+safe", at: link)
        let (_, mutationResponse) = try await browser.data(for: mutation)
        precondition((mutationResponse as? HTTPURLResponse)?.statusCode == 404)

        let (body, response) = try await browser.data(from: link)
        let received = String(decoding: body, as: UTF8.self)
        let http = response as? HTTPURLResponse
        precondition(http?.statusCode == 200)
        precondition(received.contains("Meet by A &amp; B\n&lt;gate&gt;"))
        precondition(received.contains("Home &lt;north&gt;"))
        precondition(!received.contains("<h2>Pins</h2>"))
        precondition(!received.contains("Household check-in worksheet"))
        precondition(!received.contains("Neighborhood status log"))
        precondition(http?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        let policy = http?.value(forHTTPHeaderField: "Content-Security-Policy")
        precondition(policy == page.contentSecurityPolicy)
        precondition(policy?.contains("default-src 'none'") == true)
        precondition(policy?.contains("script-src 'nonce-") == true)
        precondition(received.contains("Find in shared information"))
        precondition(received.contains("<script nonce="))

        guard case .expired = await iterator.next() else { fatalError("Unconfirmed expiry") }
        do {
            _ = try await browser.data(from: link)
            fatalError("An expired link still worked")
        } catch is URLError {}

        let (newEvents, newEmitter) = AsyncStream<HouseholdShareServer.Event>.makeStream()
        let stoppable = try HouseholdShareServer(address: loopback, page: publicPage, lifetime: 60) { event in
            newEmitter.yield(event)
        }
        var newIterator = newEvents.makeAsyncIterator()
        stoppable.start()
        guard case let .listening(newLink) = await newIterator.next() else { fatalError("Could not restart sharing") }
        precondition(newLink.lastPathComponent != link.lastPathComponent)
        let (publicBody, activeResponse) = try await browser.data(from: newLink)
        precondition((activeResponse as? HTTPURLResponse)?.statusCode == 200)
        let publicHTML = String(decoding: publicBody, as: UTF8.self)
        precondition(publicHTML.contains("<h2>Household check-in worksheet</h2>"))
        precondition(publicHTML.contains("<h2>Neighborhood status log</h2>"))
        precondition(publicHTML.contains("out-of-area contact"))
        precondition(publicHTML.contains("Correction to earlier entry and correction time"))
        precondition(!publicHTML.contains("<h2>Notes</h2>") && !publicHTML.contains("<h2>Home</h2>"))

        let unmarked = noteRequest("note=Unmarked", at: newLink, marked: false)
        let (_, unmarkedResponse) = try await browser.data(for: unmarked)
        precondition((unmarkedResponse as? HTTPURLResponse)?.statusCode == 404)
        let malformed = noteRequest("note=one&note=two", at: newLink)
        let (_, malformedResponse) = try await browser.data(for: malformed)
        precondition((malformedResponse as? HTTPURLResponse)?.statusCode == 400)

        let submission = noteRequest("note=At+the+library", at: newLink)
        let (_, acceptedResponse) = try await browser.data(for: submission)
        precondition((acceptedResponse as? HTTPURLResponse)?.statusCode == 202)
        guard case let .noteProposed(note) = await newIterator.next(), note == "At the library" else {
            fatalError("No note reached the host")
        }
        let (_, busyResponse) = try await browser.data(for: submission)
        precondition((busyResponse as? HTTPURLResponse)?.statusCode == 409)

        let homeFile = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeFile) }
        let store = HouseholdStore(file: homeFile.appendingPathComponent("household.json"))
        try store.saveNotes("Host notes edited since sharing began")
        try store.appendGuestNote(note)
        precondition(store.snapshot.notes == "Host notes edited since sharing began\n\nGuest note\nAt the library")
        stoppable.finishNoteReview()
        let next = noteRequest("note=Second+message", at: newLink)
        let (_, nextResponse) = try await browser.data(for: next)
        precondition((nextResponse as? HTTPURLResponse)?.statusCode == 202)
        guard case .noteProposed("Second message") = await newIterator.next() else {
            fatalError("The host could not receive another note")
        }

        stoppable.replaceLink()
        guard case let .listening(replacement) = await newIterator.next() else {
            fatalError("Could not replace the active sharing link")
        }
        precondition(replacement.host == newLink.host && replacement.port == newLink.port)
        precondition(replacement.lastPathComponent != newLink.lastPathComponent)
        let (revokedBody, revokedResponse) = try await browser.data(from: newLink)
        precondition((revokedResponse as? HTTPURLResponse)?.statusCode == 404)
        precondition(!String(decoding: revokedBody, as: UTF8.self).contains("Meet"))
        let (replacementBody, replacementResponse) = try await browser.data(from: replacement)
        precondition((replacementResponse as? HTTPURLResponse)?.statusCode == 200)
        precondition(replacementBody == publicBody)
        let obsolete = noteRequest("note=Outdated+link", at: newLink)
        let (_, obsoleteResponse) = try await browser.data(for: obsolete)
        precondition((obsoleteResponse as? HTTPURLResponse)?.statusCode == 404)
        let pending = noteRequest("note=Wait+for+review", at: replacement)
        let (_, pendingResponse) = try await browser.data(for: pending)
        precondition((pendingResponse as? HTTPURLResponse)?.statusCode == 409)

        stoppable.stop()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            do {
                let request = URLRequest(url: replacement, timeoutInterval: 0.5)
                _ = try await browser.data(for: request)
                try await Task.sleep(for: .milliseconds(50))
            } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                print("Verified household viewing, public references, note review, link replacement, expiry, and manual stop.")
                return
            }
        }
        fatalError("An explicitly stopped link still worked")
    }

    private static func verifyPublicReferences() throws -> [HouseholdSharePublicReference] {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let expectedIDs: Set = ["household-check-in-v1", "neighborhood-status-log-v1"]
        let catalog = NearbyPublicReference.mainCatalog.filter { expectedIDs.contains($0.id) }.map { entry in
            NearbyPublicReference(entry: entry, directory: folder,
                                  bundledFile: URL(fileURLWithPath: "Resources/NearbyPublic/\(entry.id).txt"))
        }
        let references = HouseholdSharePublicReference.verified(from: catalog)
        precondition(Set(references.map(\.id)) == expectedIDs && references.count == expectedIDs.count)

        guard let worksheet = catalog.first(where: { $0.entry.id == "household-check-in-v1" }),
              let statusLog = catalog.first(where: { $0.entry.id == "neighborhood-status-log-v1" }),
              var tampered = worksheet.loadVerified() else { fatalError("Missing verified reference fixture") }
        tampered[tampered.startIndex] ^= 1
        let tamperedFile = folder.appendingPathComponent("tampered.txt")
        try tampered.write(to: tamperedFile)
        let invalid = NearbyPublicReference(entry: worksheet.entry, directory: folder, bundledFile: tamperedFile)
        let unlisted = NearbyPublicReference(
            entry: .init(manifest: worksheet.entry.manifest, title: "Unreviewed worksheet title"),
            directory: folder, bundledFile: URL(fileURLWithPath: "Resources/NearbyPublic/\(worksheet.entry.id).txt")
        )
        precondition(unlisted.loadVerified() != nil)
        let verifiedAfterTampering = HouseholdSharePublicReference.verified(from: [invalid, unlisted, statusLog])
        precondition(verifiedAfterTampering.map(\.id) == ["neighborhood-status-log-v1"])

        let selected = HouseholdSharePublicReference.verified(from: [worksheet])
        let onePage = HouseholdSharePage(snapshot: HouseholdSnapshot(), publicReferences: selected)
        let oneHTML = String(decoding: onePage.body, as: UTF8.self)
        precondition(oneHTML.contains("<h2>Household check-in worksheet</h2>"))
        precondition(!oneHTML.contains("Neighborhood status log"))
        precondition(!oneHTML.contains("Correction to earlier entry and correction time"))

        let publicOnly = HouseholdSharePage(snapshot: HouseholdSnapshot(), publicReferences: references)
        let publicHTML = String(decoding: publicOnly.body, as: UTF8.self)
        precondition(!publicOnly.acceptsNotes)
        precondition(!publicHTML.contains("<h2>Notes</h2>") && !publicHTML.contains("<h2>Home</h2>") &&
                     !publicHTML.contains("<h2>Pins</h2>") && !publicHTML.contains("Send a note to the host"))
        precondition(publicHTML.contains("(the &quot;Software&quot;)"))
        precondition(!publicHTML.contains("(the \"Software\")"))
        precondition(publicHTML.contains("Find in shared information"))

        if let outputPath = CommandLine.arguments.dropFirst().first {
            let output = URL(fileURLWithPath: outputPath, isDirectory: true)
            try publicOnly.body.write(to: output.appendingPathComponent("public-references.html"))
            try onePage.body.write(to: output.appendingPathComponent("selected-reference.html"))
        }
        return references
    }

    private static func noteRequest(_ body: String, at url: URL, marked: Bool = true) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if marked { request.setValue("1", forHTTPHeaderField: "X-Tinfoil-Guest-Note") }
        return request
    }

}
