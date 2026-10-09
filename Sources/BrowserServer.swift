import Cocoa
import Network
import CryptoKit
import Security

struct BrowserRequest {
    let method: String, path: String
    let headers: [String: String]
    let body: Data
    let consumed: Int
    static func parse(_ data: Data) throws -> BrowserRequest? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16384 { throw BrowserFailure.invalid }; return nil
        }
        guard split.lowerBound <= 16384, let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { throw BrowserFailure.invalid }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(String(first[0])), first[1].hasPrefix("/"), !first[1].contains("#") else { throw BrowserFailure.invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw BrowserFailure.invalid }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[key] == nil else { throw BrowserFailure.invalid }
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] != nil, headers["transfer-encoding"] == nil else { throw BrowserFailure.invalid }
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(lengthText), length <= 8192 else { throw BrowserFailure.invalid }
        let end = split.upperBound + length
        guard data.count >= end else { return nil }
        return BrowserRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: data.subdata(in: split.upperBound..<end), consumed: end)
    }
    var sameOrigin: Bool {
        guard let origin = headers["origin"], let url = URL(string: origin), ["http", "https"].contains(url.scheme), url.user == nil, url.password == nil,
              let host = url.host else { return false }
        let authority = host.lowercased() + (url.port.map { ":\($0)" } ?? "")
        return authority == headers["host"]?.lowercased()
    }
    var secureOrigin: Bool { headers["origin"]?.hasPrefix("https://") == true }
    var session: String? {
        headers["cookie"]?.split(separator: ";").compactMap { part -> String? in
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            return pair.count == 2 && pair[0] == "infraproxy_session" ? String(pair[1]) : nil
        }.first
    }
}
enum BrowserFailure: Error { case invalid }
enum BrowserSecurity {
    static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

// All network/auth/PTY state is confined to this queue. No terminal bytes or credentials are logged.
final class BrowserEngine {
    let queue = DispatchQueue(label: "InfraProxy.browser")
    let assets: URL, helper: URL
    private var listener: NWListener?
    fileprivate var peers: [UUID: BrowserPeer] = [:]
    fileprivate var sessions: [String: Date] = [:]
    fileprivate var tickets: [String: (String, Date)] = [:]
    fileprivate var key = BrowserSecurity.token()
    fileprivate var hosts = Set<String>()
    fileprivate var snapshot: [String: Any] = [:]
    fileprivate var failedLogins: [Date] = []
    var onState: ((Bool, Int, String, [String]) -> Void)?
    fileprivate var port = 0
    init(assets: URL, helper: URL) { self.assets = assets; self.helper = helper }
    func start(port: Int, key: String) {
        queue.async { [self] in
            guard self.listener == nil, let portValue = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 && port <= 65535 else { return }
            self.key = key; self.port = port
            self.hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: portValue)
            parameters.allowLocalEndpointReuse = false
            do {
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.peers.count < 32 else { connection.cancel(); return }
                    let peer = BrowserPeer(connection: connection, engine: self)
                    self.peers[peer.id] = peer; peer.start()
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready: self.notify(true, "Running · localhost only")
                    case .failed: self.stopOnQueue(); self.notify(false, "Could not listen on port \(port). Choose an unused port.")
                    default: break
                    }
                }
                listener.start(queue: self.queue)
            } catch { self.listener = nil; self.notify(false, "Could not start the browser server.") }
        }
    }
    func stop() { queue.async { self.stopOnQueue(); self.notify(false, "Stopped") } }
    private func stopOnQueue() {
        listener?.cancel(); listener = nil
        for peer in Array(peers.values) { peer.close() }
        sessions.removeAll(); tickets.removeAll(); failedLogins.removeAll()
    }
    func update(snapshot: [String: Any], remoteURLs: [URL]) {
        queue.async {
            self.snapshot = snapshot
            self.hosts = Set(["127.0.0.1:\(self.port)", "localhost:\(self.port)"] + remoteURLs.compactMap { url in
                url.host.map { $0.lowercased() + (url.port.map { ":\($0)" } ?? "") }
            })
        }
    }
    func rotate(key: String) {
        queue.async {
            self.key = key; self.sessions.removeAll(); self.tickets.removeAll()
            for peer in Array(self.peers.values) where peer.webSocket { peer.close() }
            self.notify(self.listener != nil, "Access key rotated; browser sessions ended")
        }
    }
    func endTerminal(_ id: String) { queue.async { if let uuid = UUID(uuidString: id) { self.peers[uuid]?.close() } } }
    fileprivate func notify(_ running: Bool = true, _ message: String = "Running · localhost only") {
        let ids = peers.values.filter { $0.webSocket }.map { $0.id.uuidString }.sorted()
        let port = self.port
        DispatchQueue.main.async { [weak self] in self?.onState?(running, port, message, ids) }
    }
    fileprivate func validSession(_ request: BrowserRequest) -> String? {
        guard let value = request.session, let expiry = sessions[value], expiry > Date() else { return nil }
        return value
    }
}

private final class BrowserPeer {
    let id = UUID()
    let connection: NWConnection
    let engine: BrowserEngine
    var webSocket = false
    private var buffer = Data(), pendingOutput = 0
    private var closed = false
    private var process: Process?, stdin: FileHandle?, stdout: FileHandle?
    private var owner = ""
    private var expires = Date.distantPast
    private let inputQueue = DispatchQueue(label: "InfraProxy.terminal.input")
    private var pendingInput = 0
    init(connection: NWConnection, engine: BrowserEngine) { self.connection = connection; self.engine = engine }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.close() } }
        connection.start(queue: engine.queue)
        engine.queue.asyncAfter(deadline: .now() + 10) { [weak self] in if self?.webSocket == false { self?.close() } }
        receive()
    }
    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            guard self.buffer.count <= 131072 else { self.close(); return }
            do {
                if self.webSocket { try self.frames() }
                else if let request = try BrowserRequest.parse(self.buffer) {
                    self.buffer = Data(self.buffer.dropFirst(request.consumed))
                    self.route(request)
                    if self.webSocket { try self.frames() } else { return }
                }
            } catch { self.reply(400, "Invalid request"); return }
            if complete || error != nil { self.close() } else { self.receive() }
        }
    }
    private func route(_ request: BrowserRequest) {
        guard engine.hosts.contains(request.headers["host"]?.lowercased() ?? "") else { reply(403, "Unknown host"); return }
        let files = ["/": "index.html", "/app.js": "app.js", "/style.css": "style.css", "/xterm.js": "xterm.js", "/xterm.css": "xterm.css", "/fit.js": "fit.js"]
        if request.method == "GET", let file = files[request.path] {
            guard let data = try? Data(contentsOf: engine.assets.appendingPathComponent(file)) else { reply(404, "Not found"); return }
            reply(200, data: data, type: file.hasSuffix(".js") ? "text/javascript" : file.hasSuffix(".css") ? "text/css" : "text/html"); return
        }
        if request.path == "/api/login", request.method == "POST" {
            guard request.sameOrigin, request.secureOrigin || request.headers["host"] == "127.0.0.1:\(engine.port)" || request.headers["host"] == "localhost:\(engine.port)" else { reply(403, "Origin denied"); return }
            engine.failedLogins.removeAll { $0 < Date().addingTimeInterval(-60) }
            guard engine.failedLogins.count < 10 else { reply(429, "Too many attempts. Try again in a minute."); return }
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: String], BrowserSecurity.equal(object["key"] ?? "", engine.key) else {
                engine.failedLogins.append(Date()); reply(401, "Invalid access key"); return
            }
            engine.sessions = engine.sessions.filter { $0.value > Date() }
            guard engine.sessions.count < 32 else { reply(429, "Session limit reached. Rotate the access key in InfraProxy."); return }
            let session = BrowserSecurity.token(); engine.sessions[session] = Date().addingTimeInterval(28800)
            reply(200, "Signed in", extra: ["Set-Cookie": "infraproxy_session=\(session); Path=/; HttpOnly; SameSite=Strict; Max-Age=28800" + (request.secureOrigin ? "; Secure" : "")]); return
        }
        guard let session = engine.validSession(request) else { reply(401, "Sign in required"); return }
        if request.path == "/api/status", request.method == "GET" {
            var status = engine.snapshot
            status["sessions"] = engine.peers.values.filter { $0.webSocket }.map { ["id": $0.id.uuidString] }
            reply(200, data: (try? JSONSerialization.data(withJSONObject: status)) ?? Data("{}".utf8), type: "application/json"); return
        }
        guard request.sameOrigin, request.secureOrigin || request.headers["host"] == "127.0.0.1:\(engine.port)" || request.headers["host"] == "localhost:\(engine.port)" else { reply(403, "Origin denied"); return }
        if request.path == "/api/logout", request.method == "POST" {
            engine.sessions.removeValue(forKey: session)
            for peer in Array(engine.peers.values) where peer.owner == session { peer.close() }
            reply(200, "Signed out", extra: ["Set-Cookie": "infraproxy_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" + (request.secureOrigin ? "; Secure" : "")]); return
        }
        if request.path == "/api/ticket", request.method == "POST" {
            engine.tickets = engine.tickets.filter { $0.value.1 > Date() }
            guard engine.tickets.count < 32 else { reply(429, "Ticket limit reached"); return }
            let ticket = BrowserSecurity.token(); engine.tickets[ticket] = (session, Date().addingTimeInterval(30))
            reply(200, data: Data("{\"ticket\":\"\(ticket)\"}".utf8), type: "application/json"); return
        }
        if request.path == "/api/stop", request.method == "POST" {
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: String], let id = object["id"], let uuid = UUID(uuidString: id) else { reply(400, "Invalid session"); return }
            engine.peers[uuid]?.close(); reply(200, "Stopped"); return
        }
        if request.path == "/terminal", request.method == "GET" {
            let protocols = (request.headers["sec-websocket-protocol"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard protocols.count == 2, protocols[0] == "infraproxy", let ticket = engine.tickets.removeValue(forKey: protocols[1]), ticket.0 == session, ticket.1 > Date(),
                  request.headers["upgrade"]?.lowercased() == "websocket", request.headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
                  request.headers["sec-websocket-version"] == "13", let key = request.headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16,
                  engine.peers.values.filter({ $0.webSocket }).count < 8 else { reply(403, "Terminal access denied"); return }
            let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
            let accept = Data(digest).base64EncodedString()
            send(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: infraproxy\r\n\r\n".utf8))
            owner = session; expires = engine.sessions[session] ?? Date(); webSocket = true
            launchTerminal(); engine.notify()
            engine.queue.asyncAfter(deadline: .now() + max(0, expires.timeIntervalSinceNow)) { [weak self] in self?.close() }
            return
        }
        reply(404, "Not found")
    }
    private func launchTerminal() {
        let child = Process(); child.executableURL = engine.helper
        let input = Pipe(), output = Pipe()
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        // Do not pass application bootstrap secrets to shells.
        environment.removeValue(forKey: "INFRAPROXY_TEST_KEY")
        child.environment = environment
        stdin = input.fileHandleForWriting; stdout = output.fileHandleForReading; process = child
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }
            self.engine.queue.async {
                guard !self.closed else { return }
                // A pipe read can exceed the WebSocket 16-bit payload size.
                for offset in stride(from: 0, to: data.count, by: 16384) {
                    self.frame(data.subdata(in: offset..<min(offset + 16384, data.count)), opcode: 2)
                }
            }
        }
        child.terminationHandler = { [weak self] _ in guard let self else { return }; self.engine.queue.async { self.close() } }
        do { try child.run() } catch { close() }
    }
    private func frames() throws {
        while buffer.count >= 2 {
            let bytes = [UInt8](buffer.prefix(14))
            guard bytes[0] & 0x80 != 0, bytes[0] & 0x70 == 0, bytes[1] & 0x80 != 0 else { throw BrowserFailure.invalid }
            let opcode = bytes[0] & 15
            var length = Int(bytes[1] & 127), offset = 2
            if length == 126 { guard buffer.count >= 4 else { return }; length = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4 }
            else if length == 127 { throw BrowserFailure.invalid }
            guard length <= 65535, opcode < 8 || length <= 125 else { throw BrowserFailure.invalid }
            guard buffer.count >= offset + 4 + length else { return }
            let mask = Array(buffer[offset..<offset + 4]); offset += 4
            var payload = Array(buffer[offset..<offset + length]); for i in payload.indices { payload[i] ^= mask[i % 4] }
            buffer = Data(buffer.dropFirst(offset + length))
            if opcode == 8 { close(); return }
            if opcode == 9 { frame(Data(payload), opcode: 10); continue }
            if opcode == 10 { continue }
            guard opcode == 1, expires > Date(), engine.sessions[owner] != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any], let kind = object["type"] as? String else { throw BrowserFailure.invalid }
            if kind == "input", let text = object["data"] as? String {
                let data = Data(text.utf8); guard data.count <= 32768 else { throw BrowserFailure.invalid }
                let count = UInt32(data.count)
                writeInput(Data([73, UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]) + data)
            } else if kind == "resize", let cols = object["cols"] as? Int, let rows = object["rows"] as? Int, (2...500).contains(cols), (2...500).contains(rows) {
                writeInput(Data([82, UInt8(cols >> 8), UInt8(cols & 255), UInt8(rows >> 8), UInt8(rows & 255)]))
            } else { throw BrowserFailure.invalid }
        }
    }
    private func writeInput(_ data: Data) {
        guard let handle = stdin else { return }
        pendingInput += data.count
        guard pendingInput <= 262144 else { close(); return }
        inputQueue.async { [weak self] in
            let success = (try? handle.write(contentsOf: data)) != nil
            guard let self else { return }
            self.engine.queue.async { self.pendingInput -= data.count; if !success { self.close() } }
        }
    }
    private func frame(_ data: Data, opcode: UInt8) {
        var packet = Data([0x80 | opcode])
        if data.count < 126 { packet.append(UInt8(data.count)) }
        else { packet.append(contentsOf: [126, UInt8(data.count >> 8), UInt8(data.count & 255)]) }
        packet.append(data); send(packet)
    }
    private func send(_ data: Data, finish: Bool = false) {
        guard !closed else { return }
        pendingOutput += data.count
        guard pendingOutput <= 1048576 else { close(); return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }; self.pendingOutput -= data.count
            if finish || error != nil { self.close() }
        })
    }
    private func reply(_ status: Int, _ message: String, extra: [String: String] = [:]) { reply(status, data: Data(message.utf8), type: "text/plain", extra: extra) }
    private func reply(_ status: Int, data: Data, type: String, extra: [String: String] = [:]) {
        if webSocket { close(); return }
        var headers = "HTTP/1.1 \(status) Response\r\nContent-Length: \(data.count)\r\nContent-Type: \(type); charset=utf-8\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\nPermissions-Policy: camera=(), microphone=(), geolocation=()\r\nStrict-Transport-Security: max-age=31536000\r\n"
        for (key, value) in extra { headers += "\(key): \(value)\r\n" }
        send(Data((headers + "\r\n").utf8) + data, finish: true)
    }
    func close() {
        guard !closed else { return }; closed = true
        stdout?.readabilityHandler = nil
        try? stdin?.close(); stdin = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; connection.cancel(); engine.peers.removeValue(forKey: id)
        if webSocket { engine.notify() }
    }
}
