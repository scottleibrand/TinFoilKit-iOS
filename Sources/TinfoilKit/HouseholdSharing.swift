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

struct HouseholdSharePage: Sendable {
    static let basePolicy = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'"
    let body: Data
    let contentSecurityPolicy: String
    let acceptsNotes: Bool

    init(snapshot: HouseholdSnapshot, publicWorksheet: String? = nil, acceptsNotes: Bool = false) {
        self.acceptsNotes = acceptsNotes
        var content = ""
        if !snapshot.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content += "<section><h2>Notes</h2><p>\(Self.escape(snapshot.notes))</p></section>"
        }
        if let home = snapshot.home {
            content += "<section><h2>Home</h2>\(Self.place(home))</section>"
        }
        if !snapshot.pins.isEmpty {
            content += "<section><h2>Pins</h2>" + snapshot.pins.map(Self.place).joined() + "</section>"
        }
        if let publicWorksheet {
            content += "<section><h2>Public check-in worksheet</h2><p>\(Self.escape(publicWorksheet))</p></section>"
        }
        let nonce = UUID().uuidString
        let notePolicy = acceptsNotes ? "; connect-src 'self'" : ""
        contentSecurityPolicy = "\(Self.basePolicy); script-src 'nonce-\(nonce)'; form-action 'none'\(notePolicy)"
        let noteForm = acceptsNotes ? Self.noteForm : ""
        let noteScript = acceptsNotes ? Self.noteScript : ""
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
        \(content)
        \(noteForm)
        </main>
        <script nonce="\(nonce)">\(Self.searchScript)
        \(noteScript)</script>
        </html>
        """
        body = Data(html.utf8)
    }

    private static let searchScript = #"""
        const search = document.querySelector("#search");
        const input = document.querySelector("#query");
        const status = document.querySelector("#search-status");
        const sections = Array.from(document.querySelectorAll("main > section"));
        if (sections.length) {
            search.hidden = false;
            const normalize = text => text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
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
        <textarea id="note" maxlength="1000" rows="4" required></textarea>
        <button type="submit">Send for review</button>
        </form>
        <p role="status"></p>
        </div>
        """

    private static let noteScript = #"""
        const notePanel = document.querySelector("#guest-note");
        const noteForm = notePanel.querySelector("form");
        const note = noteForm.querySelector("textarea");
        const submit = noteForm.querySelector("button");
        const noteStatus = notePanel.querySelector("[role=status]");
        notePanel.hidden = false;
        noteForm.addEventListener("submit", async event => {
            event.preventDefault();
            if (submit.disabled) return;
            submit.disabled = true;
            noteStatus.textContent = "Sending…";
            try {
                const reply = await fetch(location.href, {
                    method: "POST", mode: "same-origin", credentials: "omit", redirect: "error",
                    headers: { "X-Tinfoil-Guest-Note": "1" },
                    body: new URLSearchParams({ note: note.value })
                });
                if (reply.status === 202) {
                    note.value = "";
                    noteStatus.textContent = "Sent to the host for review.";
                } else if (reply.status === 409) {
                    noteStatus.textContent = "The host already has a note to review. Try again later.";
                } else {
                    noteStatus.textContent = "The note could not be sent. Check the message and sharing link.";
                }
            } catch {
                noteStatus.textContent = "The sharing session is unavailable.";
            } finally {
                submit.disabled = false;
            }
        });
        """#

    private static func place(_ place: HouseholdPlace) -> String {
        var fragment = "<article><h3>\(escape(place.name))</h3>"
        fragment += "<p class=\"coordinates\">\(escape(place.coordinateText))</p>"
        if !place.note.isEmpty { fragment += "<p>\(escape(place.note))</p>" }
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
        case noteProposed(String)
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
    private var reviewingNote = false

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

    func finishNoteReview() {
        queue.async { [self] in reviewingNote = false }
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
              headers["host"] == ["\(address.host):\(port.rawValue)"], tokenMatches(request[1]) else {
            send(connection, id: id, text: "Not found", status: "404 Not Found")
            return
        }
        if request[0] == "GET" || request[0] == "HEAD" {
            send(connection, id: id, data: response(
                status: "200 OK", type: "text/html; charset=utf-8", body: page.body,
                headOnly: request[0] == "HEAD", contentSecurityPolicy: page.contentSecurityPolicy
            ))
        } else if request[0] == "POST", page.acceptsNotes, let length = HouseholdNoteProposal.bodyLength(headers: headers) {
            receiveNote(connection, id: id, body: initialBody, length: length, complete: complete)
        } else {
            send(connection, id: id, text: "Not found", status: "404 Not Found")
        }
    }

    private func receiveNote(_ connection: NWConnection, id: UUID, body: Data, length: Int, complete: Bool) {
        guard !closed, ContinuousClock.now < deadline else { close(id); return }
        if body.count == length {
            guard let note = HouseholdNoteProposal.parse(body) else {
                send(connection, id: id, text: "Invalid note", status: "400 Bad Request")
                return
            }
            guard !reviewingNote else {
                send(connection, id: id, text: "A note is awaiting review", status: "409 Conflict")
                return
            }
            reviewingNote = true
            event(.noteProposed(note))
            send(connection, id: id, text: "Sent for review", status: "202 Accepted")
        } else if body.count < length, !complete {
            connection.receive(minimumIncompleteLength: 1, maximumLength: length - body.count) {
                [weak self] data, _, complete, error in
                guard let self, self.connections[id] != nil else { return }
                self.receiveNote(connection, id: id, body: body + (data ?? Data()), length: length,
                                 complete: complete || error != nil)
            }
        } else {
            send(connection, id: id, text: "Incomplete note", status: "400 Bad Request")
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
                          contentSecurityPolicy: String = HouseholdSharePage.basePolicy) -> Data {
        let headers = [
            "HTTP/1.1 \(status)", "Content-Type: \(type)", "Content-Length: \(body.count)",
            "Connection: close", "Cache-Control: no-store", "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff", "X-Frame-Options: DENY",
            "Content-Security-Policy: \(contentSecurityPolicy)"
        ]
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
