import Foundation
import Network
import Security

private let registryHost = "registry.npmjs.org"
private let feedHost = "packagefeedproxy.microsoft.io"
private let bridgeQueue = DispatchQueue(label: "local.dev-cache.npm-bridge")

private struct RegistryRequest {
    let upstreamHeader: Data
    let bodyLength: Int?

    init(_ data: Data) throws {
        guard data.suffix(4) == Data("\r\n\r\n".utf8),
              let text = String(data: data.dropLast(4), encoding: .utf8) else {
            throw RouterError("Invalid HTTP request headers")
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(request[2])),
              !request[0].isEmpty, request[0].allSatisfy({ $0.isASCII && $0.isLetter }),
              request[0] != "CONNECT", request[0] != "TRACE",
              request[1].hasPrefix("/"), !request[1].hasPrefix("//"),
              !request[1].contains("#"), !request[1].contains("\\"),
              request[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw RouterError("Expected an origin-form HTTP/1.x registry request")
        }
        let path = request[1].split(separator: "?", maxSplits: 1)[0]
        guard let decoded = String(path).removingPercentEncoding,
              !decoded.contains("\\"),
              !decoded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw RouterError("Invalid registry path")
        }
        var headers: [(String, String, String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw RouterError("Invalid HTTP header") }
            let name = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || Array("!#$%&'*+-.^_`|~".utf8).contains($0) }),
                  value.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else {
                throw RouterError("Invalid HTTP header")
            }
            headers.append((name.lowercased(), value, line))
        }
        let hosts = headers.filter { $0.0 == "host" }
        guard hosts.count == 1,
              [registryHost, "\(registryHost):443"].contains(hosts[0].1.lowercased()) else {
            throw RouterError("Only registry.npmjs.org is accepted")
        }
        guard !headers.contains(where: {
            ["authorization", "proxy-authorization", "cookie", "upgrade", "trailer"].contains($0.0)
        }) else {
            throw RouterError("Credentials, protocol upgrades and request trailers are not forwarded")
        }
        let lengths = headers.filter { $0.0 == "content-length" }
        let encodings = headers.filter { $0.0 == "transfer-encoding" }
        guard lengths.count <= 1, encodings.count <= 1,
              lengths.isEmpty || encodings.isEmpty else {
            throw RouterError("Ambiguous HTTP body framing")
        }
        if let length = lengths.first?.1 {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
                  let count = Int(length) else { throw RouterError("Invalid Content-Length") }
            bodyLength = count
        } else if let encoding = encodings.first?.1 {
            guard encoding.lowercased() == "chunked" else {
                throw RouterError("Only chunked Transfer-Encoding is supported")
            }
            bodyLength = nil
        } else {
            bodyLength = 0
        }
        let connectionHeaders = Set(headers.filter { $0.0 == "connection" }
            .flatMap { $0.1.lowercased().split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            } })
        guard connectionHeaders.isDisjoint(with: ["host", "content-length", "transfer-encoding"]) else {
            throw RouterError("Connection header cannot override request framing")
        }
        let removed = connectionHeaders.union(["host", "connection", "proxy-connection", "keep-alive", "te"])
        let forwarded = headers.filter { !removed.contains($0.0) }.map { $0.2 }
        upstreamHeader = Data((
            "\(request[0]) /npm\(request[1]) HTTP/1.1\r\nHost: \(feedHost)\r\n"
            + (forwarded.isEmpty ? "" : forwarded.joined(separator: "\r\n") + "\r\n")
            + "Connection: close\r\n\r\n"
        ).utf8)
    }
}

// Preserve chunked framing while stopping at the first request, including pipelined input.
private struct RegistryBody {
    private enum State {
        case fixed(Int), size, payload(Int), terminator, end, complete
    }
    private var state: State
    private var line = Data()

    init(length: Int?) { state = length.map { .fixed($0) } ?? .size }

    mutating func consume(_ data: Data) throws -> (Data, Bool) {
        var output = Data()
        var offset = data.startIndex
        while true {
            switch state {
            case .complete:
                return (output, true)
            case .fixed(0):
                state = .complete
            case .fixed(let remaining), .payload(let remaining):
                guard offset < data.endIndex else { return (output, false) }
                let count = min(remaining, data.endIndex - offset)
                output.append(data[offset..<(offset + count)])
                offset += count
                if case .fixed = state {
                    state = .fixed(remaining - count)
                } else {
                    state = remaining == count ? .terminator : .payload(remaining - count)
                }
            case .size, .terminator, .end:
                guard offset < data.endIndex else { return (output, false) }
                line.append(data[offset])
                offset += 1
                guard line.count <= 8192 else { throw RouterError("Chunk header is too large") }
                guard line.suffix(2) == Data("\r\n".utf8) else { continue }
                switch state {
                case .size:
                    guard let text = String(data: line.dropLast(2), encoding: .ascii) else {
                        throw RouterError("Invalid chunk size")
                    }
                    let size = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    guard !size.isEmpty, size.allSatisfy({ $0.isHexDigit }),
                          let count = Int(size, radix: 16) else { throw RouterError("Invalid chunk size") }
                    state = count == 0 ? .end : .payload(count)
                case .terminator:
                    guard line.count == 2 else { throw RouterError("Invalid chunk terminator") }
                    state = .size
                case .end:
                    guard line.count == 2 else { throw RouterError("Request trailers are not supported") }
                    state = .complete
                default: break
                }
                output.append(line)
                line.removeAll(keepingCapacity: true)
            }
        }
    }
}

private final class RegistryConnection {
    let client: NWConnection
    var upstream: NWConnection?
    var header = Data()
    var body = RegistryBody(length: 0)
    var responseStarted = false
    var stopped = false
    var timer: DispatchSourceTimer?
    let finished: () -> Void

    init(client: NWConnection, finished: @escaping () -> Void) {
        self.client = client
        self.finished = finished
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: bridgeQueue)
        timer.setEventHandler { [weak self] in self?.fail("Connection idle timeout") }
        self.timer = timer
        touch()
        timer.resume()
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.readHeader()
            case .failed(let error): self?.fail("Client TLS: \(error)")
            default: break
            }
        }
        client.start(queue: bridgeQueue)
    }

    func touch() { timer?.schedule(deadline: .now() + 60) }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        timer = nil
        client.stateUpdateHandler = nil
        upstream?.stateUpdateHandler = nil
        client.cancel()
        upstream?.cancel()
        finished()
    }

    func fail(_ message: String, status: Int = 502) {
        guard !stopped else { return }
        log("npm-bridge: \(message)")
        guard !responseStarted else { stop(); return }
        responseStarted = true
        let payload = Data("npm-bridge: \(message)\n".utf8)
        let response = Data(("HTTP/1.1 \(status) Bridge Error\r\nConnection: close\r\n"
            + "Content-Type: text/plain\r\nContent-Length: \(payload.count)\r\n\r\n").utf8) + payload
        client.send(content: response, contentContext: .finalMessage,
                    completion: .contentProcessed { [weak self] _ in self?.stop() })
    }

    func readHeader() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, ended, error in
            guard !stopped else { return }
            if let error { fail("Reading request: \(error)"); return }
            if let data { header.append(data); touch() }
            if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                guard end.upperBound <= 65536 else { fail("Headers exceed 64 KiB", status: 431); return }
                do {
                    let request = try RegistryRequest(header.subdata(in: 0..<end.upperBound))
                    body = RegistryBody(length: request.bodyLength)
                    let initialBody = header.subdata(in: end.upperBound..<header.count)
                    header.removeAll()
                    connect(request.upstreamHeader, initialBody: initialBody, ended: ended)
                } catch { fail(String(describing: error), status: 400) }
            } else if header.count > 65536 {
                fail("Headers exceed 64 KiB", status: 431)
            } else if ended {
                fail("Incomplete request headers", status: 400)
            } else {
                readHeader()
            }
        }
    }

    func connect(_ header: Data, initialBody: Data, ended: Bool) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, feedHost)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let connection = NWConnection(host: NWEndpoint.Host(feedHost), port: 443,
                                      using: NWParameters(tls: tls))
        upstream = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !stopped else { return }
            switch state {
            case .ready:
                touch()
                relayResponse()
                connection.send(content: header, completion: .contentProcessed { [weak self] error in
                    guard let self, !stopped else { return }
                    if let error { fail("Sending upstream headers: \(error)"); return }
                    sendBody(initialBody, ended: ended)
                })
            case .failed(let error): fail("Upstream TLS/connect: \(error)")
            case .waiting(let error): fail("Upstream unavailable: \(error)")
            default: break
            }
        }
        connection.start(queue: bridgeQueue)
    }

    func sendBody(_ data: Data, ended: Bool) {
        guard !stopped else { return }
        do {
            let (bytes, complete) = try body.consume(data)
            guard !ended || complete else { fail("Incomplete request body", status: 400); return }
            upstream?.send(content: bytes, completion: .contentProcessed { [weak self] error in
                guard let self, !stopped else { return }
                if let error { fail("Sending upstream body: \(error)"); return }
                touch()
                if !complete { readBody() }
            })
        } catch { fail(String(describing: error), status: 400) }
    }

    func readBody() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, ended, error in
            guard let self, !stopped else { return }
            if let error { fail("Reading request body: \(error)"); return }
            sendBody(data ?? Data(), ended: ended)
        }
    }

    func relayResponse() {
        upstream?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, ended, error in
            guard let self, !stopped else { return }
            if let error { fail("Reading upstream response: \(error)"); return }
            if let data, !data.isEmpty { responseStarted = true; touch() }
            client.send(content: data, contentContext: ended ? .finalMessage : .defaultMessage,
                        completion: .contentProcessed { [weak self] error in
                guard let self, !stopped else { return }
                if let error { fail("Writing response: \(error)"); return }
                if ended { stop() } else { relayResponse() }
            })
        }
    }
}

func runNpmBridge(identityPath: String, port: UInt16 = 443, loginEnvironment: Bool = false) throws {
    var imported: CFArray?
    let passwordData = try Data(contentsOf: URL(fileURLWithPath: identityPath + ".password"))
    guard let password = String(data: passwordData, encoding: .utf8)?
        .trimmingCharacters(in: .newlines), !password.isEmpty else {
        throw RouterError("Invalid bridge identity password file")
    }
    let options = [kSecImportExportPassphrase as String: password,
                   kSecImportToMemoryOnly as String: true] as CFDictionary
    let status = SecPKCS12Import(try Data(contentsOf: URL(fileURLWithPath: identityPath)) as CFData,
                                options, &imported)
    guard status == errSecSuccess,
          let entries = imported as? [[String: Any]],
          let value = entries.first?[kSecImportItemIdentity as String],
          CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
        throw RouterError("Cannot import bridge identity (Security status \(status))")
    }
    // Security validates the CF type above; SecIdentity has no conditional Swift cast.
    let identity = unsafeDowncast(value as AnyObject, to: SecIdentity.self)
    guard let localIdentity = sec_identity_create(identity) else {
        throw RouterError("Cannot create TLS identity")
    }
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
    sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
    guard let listenPort = NWEndpoint.Port(rawValue: port), port != 0 else {
        throw RouterError("Invalid bridge port")
    }
    if loginEnvironment {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        let certificate = URL(fileURLWithPath: identityPath).deletingLastPathComponent()
            .appendingPathComponent("certificate.pem").path
        process.arguments = ["setenv", "NODE_EXTRA_CA_CERTS", certificate]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RouterError("Cannot configure login Node CA environment") }
    }
    let listeners = try ["127.0.0.1", "::1"].map { host -> NWListener in
        let parameters = NWParameters(tls: tls)
        parameters.allowLocalEndpointReuse = true
        guard let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options else {
            throw RouterError("Cannot configure loopback IP version")
        }
        ip.version = host == "::1" ? .v6 : .v4
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: listenPort)
        return try NWListener(using: parameters)
    }
    var connections: [UUID: RegistryConnection] = [:]
    for listener in listeners {
        listener.newConnectionHandler = { client in
            guard connections.count < 128 else {
                log("npm-bridge: connection limit reached")
                client.cancel()
                return
            }
            let id = UUID()
            let connection = RegistryConnection(client: client) { connections.removeValue(forKey: id) }
            connections[id] = connection
            connection.start()
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: log("npm-bridge: loopback listener ready on port \(port), forwarding to https://\(feedHost)/npm/")
            case .failed(let error):
                log("npm-bridge: listener failed: \(error)")
                exit(1)
            default: break
            }
        }
        listener.start(queue: bridgeQueue)
    }
    dispatchMain()
}

func testNpmBridge() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RouterError(message) }
    }
    func request(_ target: String = "/@scope%2fname?x=1", extra: String = "") throws -> RegistryRequest {
        try RegistryRequest(Data("GET \(target) HTTP/1.1\r\nHost: registry.npmjs.org\r\n\(extra)\r\n".utf8))
    }
    let routed = try request(extra: "Accept: application/json\r\nConnection: keep-alive, X-Remove\r\nX-Remove: no\r\n")
    let forwarded = String(decoding: routed.upstreamHeader, as: UTF8.self)
    try check(forwarded.hasPrefix("GET /npm/@scope%2fname?x=1 HTTP/1.1\r\nHost: \(feedHost)\r\n"),
              "Scoped path/query was changed")
    try check(forwarded.contains("Accept: application/json\r\n") && !forwarded.contains("X-Remove"),
              "Hop-by-hop header handling failed")
    for extra in [
        "Authorization: Bearer secret\r\n", "Cookie: secret\r\n", "Upgrade: websocket\r\n",
        "Host: evil.example\r\n", "Content-Length: 1\r\nContent-Length: 2\r\n",
        "Content-Length: -1\r\n", "Content-Length: 1\r\nTransfer-Encoding: chunked\r\n",
        "Transfer-Encoding: gzip\r\n", "Connection: content-length\r\n", " Bad: folded\r\n",
        "Trailer: Authorization\r\n"
    ] {
        do {
            _ = try request(extra: extra)
            throw RouterError("Unsafe request was accepted: \(extra.components(separatedBy: ":")[0])")
        } catch let error as RouterError {
            guard !error.description.hasPrefix("Unsafe request was accepted") else { throw error }
        }
    }
    for target in ["//evil.example/", "/../other", "/%2e%2e/other", "/a#fragment"] {
        do {
            _ = try request(target)
            throw RouterError("Unsafe path was accepted")
        } catch let error as RouterError {
            guard error.description != "Unsafe path was accepted" else { throw error }
        }
    }
    var fixed = RegistryBody(length: 5)
    let (first, firstDone) = try fixed.consume(Data("he".utf8))
    let (last, lastDone) = try fixed.consume(Data("lloGET /next".utf8))
    try check(first + last == Data("hello".utf8) && !firstDone && lastDone,
              "Fixed body framing forwarded pipelined bytes")
    let chunked = Data("3;ext=yes\r\nabc\r\n2\r\nde\r\n0\r\n\r\n".utf8)
    for split in 0...chunked.count {
        var body = RegistryBody(length: nil)
        let (a, _) = try body.consume(chunked.prefix(split))
        let (b, complete) = try body.consume(chunked.dropFirst(split) + Data("GET /next".utf8))
        try check(a + b == chunked && complete, "Split chunked framing failed at \(split)")
    }
    for invalid in ["z\r\n", "1\r\nxBAD\r\n", "0\r\nAuthorization: secret\r\n\r\n"] {
        var body = RegistryBody(length: nil)
        do {
            _ = try body.consume(Data(invalid.utf8))
            throw RouterError("Invalid chunk framing accepted")
        } catch let error as RouterError {
            guard error.description != "Invalid chunk framing accepted" else { throw error }
        }
    }
    print("PASS: registry rewriting, credential rejection, HTTP framing, split chunked uploads and pipelining isolation")
}
