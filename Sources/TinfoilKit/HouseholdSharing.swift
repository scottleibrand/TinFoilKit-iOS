import Darwin
import Foundation
import Network
import Security

struct HouseholdShareAddress: Equatable, Sendable {
    let interface: String
    let host: String
    let address: UInt32
    let mask: UInt32

    func accepts(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(.ipv4(peer), _) = endpoint else { return false }
        let remote = peer.rawValue.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        return remote & mask == address & mask
    }

    static func local(in interfaces: [NWInterface]) -> Self? {
        let names = interfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }.map(\.name)
        guard !names.isEmpty else { return nil }
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var found: [Self] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = addresses
        while let entry = cursor {
            let item = entry.pointee
            cursor = item.ifa_next
            guard let raw = item.ifa_addr, let netmask = item.ifa_netmask,
                  raw.pointee.sa_family == AF_INET,
                  item.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: item.ifa_name)
            guard names.contains(name) else { continue }
            let hostIP = ipv4(raw)
            let maskIP = ipv4(netmask)
            let address = UInt32(bigEndian: hostIP.s_addr)
            let mask = UInt32(bigEndian: maskIP.s_addr)
            guard isLocal(address), mask != 0, let host = text(hostIP) else { continue }
            found.append(Self(interface: name, host: host, address: address, mask: mask))
        }
        return names.lazy.compactMap { name in found.first { $0.interface == name } }.first
    }

    private static func isLocal(_ address: UInt32) -> Bool {
        address >> 24 == 10 || address >> 20 == 0xac1 ||
        address >> 16 == 0xc0a8 || address >> 16 == 0xa9fe
    }

    private static func ipv4(_ socket: UnsafePointer<sockaddr>) -> in_addr {
        socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }

    private static func text(_ address: in_addr) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }
}

struct HouseholdSharePublicReference: Identifiable, Sendable {
    let id: String
    let title: String
    let text: String

    init(id: String, title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }

    static func verified(from references: [NearbyPublicReference]) -> [Self] {
        references.compactMap { reference in
            guard NearbyPublicReference.mainCatalog.contains(reference.entry),
                  let bytes = reference.loadVerified(),
                  let text = String(data: bytes, encoding: .utf8) else { return nil }
            return Self(id: reference.entry.id, title: reference.entry.title, text: text)
        }
    }
}

struct HouseholdShareDirections: Sendable {
    let pinID: UUID
    let modeTitle: String
    let region: String
    let edition: String
    let steps: [String]
}

struct HouseholdSharePage: Sendable {
    static let basePolicy = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'"
    static let waypointQuery = "download=waypoints"
    let body: Data
    let waypointDownload: Data?
    let contentSecurityPolicy: String
    let acceptsNotes: Bool
    let acceptsPins: Bool

    init(snapshot: HouseholdSnapshot, publicReferences: [HouseholdSharePublicReference] = [],
         directions: [HouseholdShareDirections] = [],
         acceptsNotes: Bool = false, acceptsPins: Bool = false) {
        self.acceptsNotes = acceptsNotes
        self.acceptsPins = acceptsPins
        let sharedPlaces = [snapshot.home].compactMap { $0 } + snapshot.pins
        waypointDownload = Self.waypoints(sharedPlaces)
        var content = ""
        if !snapshot.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content += "<section><h2>Notes</h2><p>\(Self.escape(snapshot.notes))</p></section>"
        }
        if let home = snapshot.home {
            content += "<section><h2>Home</h2>\(Self.place(home))</section>"
        }
        if !snapshot.pins.isEmpty {
            let byPin = Dictionary(grouping: snapshot.home == nil ? [] : directions, by: \.pinID)
            content += "<section><h2>Pins</h2>"
            content += snapshot.pins.map { Self.place($0, directions: byPin[$0.id] ?? []) }.joined()
            content += "</section>"
        }
        for reference in publicReferences {
            content += Self.publicReference(reference)
        }
        let nonce = UUID().uuidString
        let submissions = acceptsNotes || acceptsPins
        let proposalPolicy = submissions ? "; connect-src 'self'" : ""
        contentSecurityPolicy = "\(Self.basePolicy); script-src 'nonce-\(nonce)'; form-action 'none'\(proposalPolicy)"
        let html = """
        <!doctype html>
        <html lang="en">
        <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer"><title>Household information</title>
        <style>
        :root{color-scheme:light dark}body{margin:2rem auto;padding:0 1.25rem;max-width:42rem;font:1rem/1.55 system-ui,sans-serif}
        h1,h2{line-height:1.2}section{border-top:1px solid GrayText;margin:1.4rem 0}
        p{white-space:pre-wrap;overflow-wrap:anywhere}.coordinates{font-variant-numeric:tabular-nums}
        input,textarea{display:block;box-sizing:border-box;width:100%;font:inherit;padding:.5rem;margin:.3rem 0}
        </style>
        <main>
        <h1>Household information</h1>
        <div id="search" hidden role="search">
        <label for="query">Find in shared information</label>
        <input id="query" type="search" maxlength="120" autocomplete="off">
        <p id="search-status" role="status"></p>
        </div>
        \(publicReferences.isEmpty ? "" : Self.sharedAskForm)
        \(content)
        \(waypointDownload == nil ? "" : Self.waypointLink)
        \(acceptsNotes ? Self.noteForm : "")
        \(acceptsPins ? Self.pinForm : "")
        </main>
        <script nonce="\(nonce)">\(Self.searchScript)
        \(publicReferences.isEmpty ? "" : Self.sharedAskScript)
        \(submissions ? Self.proposalScript : "")</script>
        </html>
        """
        body = Data(html.utf8)
    }

    private static func publicReference(_ reference: HouseholdSharePublicReference) -> String {
        var includesPassages = true
        let paragraphs = reference.text.components(separatedBy: "\n\n").enumerated().map { index, paragraph in
            if paragraph.hasPrefix("Blank ") || paragraph.hasPrefix("Original Tinfoil Kit reference") {
                includesPassages = false
            }
            let text = escape(paragraph)
            guard index > 0, includesPassages, !paragraph.hasPrefix("Example:") else { return "<p>\(text)</p>" }
            return "<p id=\"reference-\(escape(reference.id))-\(index)\" data-reference-passage>\(text)</p>"
        }
        return "<section data-public-reference><h2>\(escape(reference.title))</h2>\(paragraphs.joined())</section>"
    }

    private static let sharedAskForm = """
        <div id="shared-ask" hidden>
        <h2>Ask shared public references</h2>
        <form>
        <label for="shared-question">Question</label>
        <input id="shared-question" maxlength="120" autocomplete="off" required>
        <button type="submit">Find cited quotes</button>
        </form>
        <p>Questions stay in this browser.</p>
        <p id="shared-ask-status" role="status"></p>
        <div id="shared-ask-results"></div>
        </div>
        """

    private static let sharedAskScript = #"""
        {
            const panel = document.querySelector("#shared-ask");
            const question = document.querySelector("#shared-question");
            const feedback = document.querySelector("#shared-ask-status");
            const results = document.querySelector("#shared-ask-results");
            const words = text => new Set(normalize(text).match(/[\p{L}\p{N}]+/gu) || []);
            const filler = new Set("a an and are as at be can could did do does for from had has have how i in is it me my of on or our please should tell that the their this to was we were what when where which who why will with would you your".split(" "));
            const references = Array.from(document.querySelectorAll("[data-public-reference]"), section => ({
                section,
                title: section.querySelector("h2").textContent,
                passages: Array.from(section.querySelectorAll("[data-reference-passage]"), node => ({
                    id: node.id, text: node.textContent, keywords: words(node.textContent)
                }))
            }));
            panel.hidden = false;
            question.addEventListener("input", () => {
                results.replaceChildren();
                feedback.textContent = "";
            });
            panel.querySelector("form").addEventListener("submit", event => {
                event.preventDefault();
                results.replaceChildren();
                const terms = Array.from(words(question.value.slice(0, 120))).filter(word => !filler.has(word));
                if (terms.length < 2) {
                    feedback.textContent = "Enter at least two topic words.";
                    return;
                }
                let count = 0;
                for (const reference of references) {
                    const match = reference.passages.find(passage => terms.every(word => passage.keywords.has(word)));
                    if (!match) continue;
                    const quote = document.createElement("blockquote");
                    quote.textContent = match.text;
                    const citation = document.createElement("a");
                    citation.href = "#" + match.id;
                    citation.textContent = "[" + (++count) + "] " + reference.title;
                    citation.addEventListener("click", () => {
                        if (reference.section.hidden) {
                            input.value = "";
                            input.dispatchEvent(new Event("input"));
                        }
                    });
                    const row = document.createElement("div");
                    row.append(quote, citation);
                    results.append(row);
                    if (count == 2) break;
                }
                feedback.textContent = count ? "Matching quotes" : "No matching quote in the shared public references.";
            });
        }
        """#

    private static let waypointLink = """
        <p><a href="?\(waypointQuery)" download="household-waypoints.gpx">Download shared locations (.gpx)</a></p>
        """

    private static func waypoints(_ places: [HouseholdPlace]) -> Data? {
        let waypoints = places.compactMap { place -> String? in
            guard (-90...90).contains(place.latitude), (-180...180).contains(place.longitude) else { return nil }
            let locale = Locale(identifier: "en_US_POSIX")
            let latitude = String(format: "%.8f", locale: locale, place.latitude)
            let roundedLongitude = String(format: "%.8f", locale: locale, place.longitude)
            let longitude = roundedLongitude == "180.00000000" ? "-180.00000000" : roundedLongitude
            // XML 1.0 excludes most control characters. A location name is the only free-text field.
            let scalars = place.name.unicodeScalars.filter { scalar in
                switch scalar.value {
                case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: true
                default: false
                }
            }
            let name = String(String.UnicodeScalarView(scalars))
            return "<wpt lat=\"\(latitude)\" lon=\"\(longitude)\"><name>\(escape(name))</name></wpt>"
        }
        guard !waypoints.isEmpty else { return nil }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Tinfoil Kit" xmlns="http://www.topografix.com/GPX/1/1">
        \(waypoints.joined(separator: "\n"))
        </gpx>
        """
        return Data(xml.utf8)
    }

    private static let searchScript = #"""
        const search = document.querySelector("#search");
        const input = document.querySelector("#query");
        const status = document.querySelector("#search-status");
        const sections = Array.from(document.querySelectorAll("main > section"));
        const normalize = text => text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
        if (sections.length) {
            search.hidden = false;
            const entries = sections.map(section => {
                const pins = Array.from(section.querySelectorAll("article"));
                return { section, pins, text: normalize(section.textContent),
                         pinText: pins.map(pin => normalize(pin.textContent)) };
            });
            input.addEventListener("input", () => {
                const query = normalize(input.value.trim().slice(0, 120));
                let matched = false;
                for (const entry of entries) {
                    if (entry.pins.length) {
                        const heading = normalize(entry.section.querySelector("h2").textContent);
                        entry.pins.forEach((pin, i) => {
                            pin.hidden = !heading.includes(query) && !entry.pinText[i].includes(query);
                        });
                        entry.section.hidden = entry.pins.every(pin => pin.hidden);
                    } else {
                        entry.section.hidden = !entry.text.includes(query);
                    }
                    matched ||= !entry.section.hidden;
                }
                status.textContent = matched ? "" : "No matches in shared information.";
            });
        }
        """#

    private static let noteForm = """
        <div id="guest-note" hidden>
        <h2>Send a note to the host</h2>
        <form>
        <label for="note">Note for review</label>
        <textarea id="note" name="note" maxlength="1000" rows="4" required></textarea>
        <button type="submit">Send for review</button>
        </form>
        <p role="status"></p>
        </div>
        """

    private static let pinForm = """
        <div id="guest-pin" hidden>
        <h2>Suggest a map pin</h2>
        <form>
        <label for="pin-name">Place name</label>
        <input id="pin-name" name="name" maxlength="80" required>
        <label for="pin-coordinates">Latitude, longitude</label>
        <input id="pin-coordinates" name="coordinates" maxlength="120" placeholder="47.6062, -122.3321" required>
        <label for="pin-note">Note (optional)</label>
        <textarea id="pin-note" name="note" maxlength="500" rows="3"></textarea>
        <button type="submit">Send pin for review</button>
        </form>
        <p role="status"></p>
        </div>
        """

    private static let proposalScript = #"""
        function acceptProposal(panelID, marker) {
          const panel = document.querySelector(panelID);
          if (!panel) return;
          const form = panel.querySelector("form");
          const submit = form.querySelector("button");
          const feedback = panel.querySelector("[role=status]");
          panel.hidden = false;
          form.addEventListener("submit", async event => {
            event.preventDefault();
            if (submit.disabled) return;
            submit.disabled = true;
            feedback.textContent = "Sending…";
            try {
                const reply = await fetch(location.href, {
                    method: "POST", mode: "same-origin", credentials: "omit", redirect: "error",
                    headers: { [marker]: "1" },
                    body: new URLSearchParams(new FormData(form))
                });
                if (reply.status === 202) {
                    form.reset();
                    feedback.textContent = "Sent to the host for review.";
                } else if (reply.status === 409) {
                    feedback.textContent = "The host already has a submission to review. Try again later.";
                } else {
                    feedback.textContent = "Could not send this submission. Check the entered information and sharing link.";
                }
            } catch {
                feedback.textContent = "The sharing session is unavailable.";
            } finally {
                submit.disabled = false;
            }
          });
        }
        acceptProposal("#guest-note", "X-Tinfoil-Guest-Note");
        acceptProposal("#guest-pin", "X-Tinfoil-Guest-Pin");
        """#

    private static func place(_ place: HouseholdPlace, directions: [HouseholdShareDirections] = []) -> String {
        var fragment = "<article><h3>\(escape(place.name))</h3>"
        fragment += "<p class=\"coordinates\">\(escape(place.coordinateText))</p>"
        if !place.note.isEmpty { fragment += "<p>\(escape(place.note))</p>" }
        for route in directions {
            let steps = route.steps.map { "<li>\(escape($0))</li>" }.joined()
            fragment += """
                <details><summary>\(escape(route.modeTitle)) directions from Home</summary>
                <ol>\(steps)</ol>
                <p>\(escape(route.region)) · \(escape(route.edition))</p>
                <p><a href="https://www.openstreetmap.org/copyright">© OpenStreetMap contributors · ODbL 1.0</a></p>
                <p>Road and access conditions may have changed since this data was published.</p>
                </details>
                """
        }
        return fragment + "</article>"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// Owns a single in-memory browser session. Listener state and connection state use the same queue.
final class HouseholdShareServer: @unchecked Sendable {
    enum Event: Sendable {
        case listening(URL)
        case failed(String)
        case expired
        case proposal(HouseholdGuestProposal)
    }

    private static let maximumHeaderBytes = 8_192
    private static let headerEnd = Data([13, 10, 13, 10])
    static let defaultLifetime: TimeInterval = 10 * 60

    private let queue = DispatchQueue(label: "org.tinfoilkit.household-share")
    private let listener: NWListener
    private let address: HouseholdShareAddress
    private let event: @Sendable (Event) -> Void
    private var resourcePath: String
    private let page: HouseholdSharePage
    private let lifetime: TimeInterval
    private let deadline: ContinuousClock.Instant
    private var connections: [UUID: NWConnection] = [:]
    private var closed = false
    private var reviewingProposal = false

    init(address: HouseholdShareAddress, page: HouseholdSharePage, lifetime: TimeInterval = defaultLifetime,
         event: @escaping @Sendable (Event) -> Void) throws {
        self.address = address
        self.page = page
        self.event = event
        self.lifetime = lifetime
        self.deadline = ContinuousClock.now + .seconds(lifetime)
        resourcePath = try Self.makeResourcePath()
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address.host), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.publishLink()
            case let .waiting(error), let .failed(error):
                self.finish(.failed(error.localizedDescription))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + lifetime) { [weak self] in self?.finish(.expired) }
    }

    func finishProposalReview() {
        queue.async { [self] in reviewingProposal = false }
    }

    func replaceLink() {
        queue.async { [self] in
            guard !closed, ContinuousClock.now < deadline else { return }
            do {
                resourcePath = try Self.makeResourcePath()
                for connection in connections.values { connection.cancel() }
                connections.removeAll()
                publishLink()
            } catch {
                finish(.failed(error.localizedDescription))
            }
        }
    }

    private func publishLink() {
        if let port = listener.port,
           let url = URL(string: "http://\(address.host):\(port.rawValue)\(resourcePath)") {
            event(.listening(url))
        } else {
            finish(.failed("The phone could not create a sharing link."))
        }
    }

    private static func makeResourcePath() throws -> String {
        var entropy = [UInt8](repeating: 0, count: 32)
        let status = entropy.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ShareError.tokenUnavailable }
        return "/household/" + entropy.map { String(format: "%02x", $0) }.joined()
    }

    func stop() {
        queue.async { [self] in finish(nil) }
    }

    private func finish(_ reason: Event?) {
        guard !closed else { return }
        closed = true
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        if let reason { event(reason) }
    }

    private func accept(_ connection: NWConnection) {
        guard !closed, ContinuousClock.now < deadline, connections.count < 8,
              address.accepts(connection.endpoint) else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id, received: Data())
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.close(id) }
    }

    private func receive(_ connection: NWConnection, id: UUID, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumHeaderBytes - received.count) {
            [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var buffer = received
            if let data { buffer.append(data) }
            if let delimiter = buffer.range(of: Self.headerEnd) {
                let header = Data(buffer.prefix(upTo: delimiter.lowerBound))
                let body = Data(buffer.suffix(from: delimiter.upperBound))
                self.route(connection, id: id, header: header, initialBody: body, complete: complete || error != nil)
            } else if buffer.count == Self.maximumHeaderBytes || complete || error != nil {
                self.close(id)
            } else {
                self.receive(connection, id: id, received: buffer)
            }
        }
    }

    private func route(_ connection: NWConnection, id: UUID, header: Data, initialBody: Data, complete: Bool) {
        guard !closed, ContinuousClock.now < deadline else { close(id); return }
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ", omittingEmptySubsequences: false) ?? []
        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name, default: []].append(value)
        }
        guard let port = listener.port, request.count == 3,
              request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0",
              headers["host"] == ["\(address.host):\(port.rawValue)"] else {
            send(connection, id: id, text: "Not found", status: "404 Not Found")
            return
        }
        let target = request[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = target.first, tokenMatches(path) else {
            send(connection, id: id, text: "Not found", status: "404 Not Found")
            return
        }
        if target.count == 2 {
            if (request[0] == "GET" || request[0] == "HEAD"), target[1] == HouseholdSharePage.waypointQuery,
               let waypoints = page.waypointDownload {
                send(connection, id: id, data: response(
                    status: "200 OK", type: "application/gpx+xml", body: waypoints,
                    headOnly: request[0] == "HEAD", attachment: "household-waypoints.gpx"
                ))
            } else {
                send(connection, id: id, text: "Not found", status: "404 Not Found")
            }
            return
        }
        if request[0] == "GET" || request[0] == "HEAD" {
            send(connection, id: id, data: response(
                status: "200 OK", type: "text/html; charset=utf-8", body: page.body,
                headOnly: request[0] == "HEAD", contentSecurityPolicy: page.contentSecurityPolicy
            ))
        } else if request[0] == "POST", let kind = HouseholdGuestProposal.Kind.permitted(
            headers: headers, acceptsNotes: page.acceptsNotes, acceptsPins: page.acceptsPins),
                  let length = HouseholdNoteProposal.bodyLength(headers: headers, marker: kind.marker) {
            receiveProposal(connection, id: id, kind: kind, body: initialBody, length: length, complete: complete)
        } else {
            send(connection, id: id, text: "Not found", status: "404 Not Found")
        }
    }

    private func receiveProposal(_ connection: NWConnection, id: UUID, kind: HouseholdGuestProposal.Kind, body: Data,
                                 length: Int, complete: Bool) {
        guard !closed, ContinuousClock.now < deadline else { close(id); return }
        if body.count == length {
            guard let proposal = kind.parse(body) else {
                send(connection, id: id, text: "Invalid submission", status: "400 Bad Request")
                return
            }
            guard !reviewingProposal else {
                send(connection, id: id, text: "A submission is awaiting review", status: "409 Conflict")
                return
            }
            reviewingProposal = true
            event(.proposal(proposal))
            send(connection, id: id, text: "Sent for review", status: "202 Accepted")
        } else if body.count < length, !complete {
            connection.receive(minimumIncompleteLength: 1, maximumLength: length - body.count) {
                [weak self] data, _, complete, error in
                guard let self, self.connections[id] != nil else { return }
                self.receiveProposal(connection, id: id, kind: kind, body: body + (data ?? Data()), length: length,
                                     complete: complete || error != nil)
            }
        } else {
            send(connection, id: id, text: "Incomplete submission", status: "400 Bad Request")
        }
    }

    private func send(_ connection: NWConnection, id: UUID, text: String, status: String) {
        send(connection, id: id, data: response(status: status, type: "text/plain; charset=utf-8", body: Data(text.utf8)))
    }

    private func send(_ connection: NWConnection, id: UUID, data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }

    private func tokenMatches(_ path: Substring) -> Bool {
        guard path.utf8.count == resourcePath.utf8.count else { return false }
        var difference: UInt8 = 0
        for (candidate, expected) in zip(path.utf8, resourcePath.utf8) { difference |= candidate ^ expected }
        return difference == 0
    }

    private func response(status: String, type: String, body: Data, headOnly: Bool = false,
                          contentSecurityPolicy: String = HouseholdSharePage.basePolicy, attachment: String? = nil) -> Data {
        var headers = [
            "HTTP/1.1 \(status)", "Content-Type: \(type)", "Content-Length: \(body.count)",
            "Connection: close", "Cache-Control: no-store", "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff", "X-Frame-Options: DENY",
            "Content-Security-Policy: \(contentSecurityPolicy)"
        ]
        if let attachment { headers.append("Content-Disposition: attachment; filename=\"\(attachment)\"") }
        var response = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if !headOnly { response.append(body) }
        return response
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }

    private enum ShareError: LocalizedError {
        case tokenUnavailable
        var errorDescription: String? { "Could not create a private sharing link." }
    }
}
