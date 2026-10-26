import Foundation
import Network
import CryptoKit

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String] // lower-cased names
    var remote: String
}

struct HTTPResponse {
    var status: Int = 200
    var reason: String = "OK"
    var headers: [String: String] = [:]
    var body = Data()

    static func text(_ s: String, status: Int = 200, reason: String = "OK", type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, headers: ["Content-Type": type], body: Data(s.utf8))
    }
    static func redirect(_ location: String) -> HTTPResponse {
        HTTPResponse(status: 302, reason: "Found", headers: ["Location": location], body: Data())
    }
    static let notFound = HTTPResponse.text("Not found", status: 404, reason: "Not Found")
}

/// Tiny HTTP/1.1 server on Network.framework: static files, a few routes, and WebSocket upgrades.
/// One request per connection (Connection: close) keeps it simple; the WebSocket is the hot path.
final class WebServer {
    typealias Router = (HTTPRequest) -> HTTPResponse
    typealias WebSocketHandler = (WebSocket, HTTPRequest) -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "remotemac.web")
    private let router: Router
    private let onWebSocket: WebSocketHandler?
    let port: UInt16

    init(port: UInt16, identity: SecIdentity?, router: @escaping Router, onWebSocket: WebSocketHandler?) throws {
        self.port = port
        self.router = router
        self.onWebSocket = onWebSocket
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params: NWParameters
        if let identity, let secId = sec_identity_create(identity) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secId)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            HTTPConnection(conn: conn, queue: self.queue, router: self.router, onWebSocket: self.onWebSocket).start()
        }
        listener.stateUpdateHandler = { [port] state in
            switch state {
            case .ready: Log.info("listening on port \(port)")
            case .failed(let err): Log.info("listener on \(port) failed: \(err)")
            default: break
            }
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }
}

private final class HTTPConnection {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let router: WebServer.Router
    private let onWebSocket: WebServer.WebSocketHandler?
    private var buffer = Data()
    private var keepAlive: HTTPConnection?

    init(conn: NWConnection, queue: DispatchQueue, router: @escaping WebServer.Router,
         onWebSocket: WebServer.WebSocketHandler?) {
        self.conn = conn
        self.queue = queue
        self.router = router
        self.onWebSocket = onWebSocket
    }

    func start() {
        keepAlive = self
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
            if case .cancelled = state { self?.keepAlive = nil }
        }
        conn.start(queue: queue)
        // Drop connections that never send a full request header.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            if let self, self.keepAlive != nil, !self.upgraded { self.finish() }
        }
        read()
    }

    private var upgraded = false

    private func finish() {
        conn.cancel()
        keepAlive = nil
    }

    private func read() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = self.buffer.subdata(in: self.buffer.startIndex..<end.lowerBound)
                let rest = self.buffer.subdata(in: end.upperBound..<self.buffer.endIndex)
                self.handle(head: head, rest: rest)
            } else if error != nil || done || self.buffer.count > 32 * 1024 {
                self.finish()
            } else {
                self.read()
            }
        }
    }

    private func remoteAddress() -> String {
        if case let .hostPort(host, _) = conn.endpoint {
            var s = "\(host)"
            if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
            return s
        }
        return "?"
    }

    private func handle(head: Data, rest: Data) {
        guard let text = String(data: head, encoding: .utf8) else { return finish() }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return finish() }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(parts[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let req = HTTPRequest(method: String(parts[0]), path: comps?.percentEncodedPath.removingPercentEncoding ?? "/",
                              query: query, headers: headers, remote: remoteAddress())

        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"],
           let onWebSocket {
            upgraded = true
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                .base64EncodedString()
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
            let ws = WebSocket(conn: conn, queue: queue, initial: rest)
            keepAlive = nil // the WebSocket owns the connection now
            onWebSocket(ws, req)
            ws.start()
            return
        }

        var resp = router(req)
        resp.headers["Content-Length"] = "\(resp.body.count)"
        resp.headers["Connection"] = "close"
        resp.headers["X-Content-Type-Options"] = "nosniff"
        if resp.headers["Cache-Control"] == nil { resp.headers["Cache-Control"] = "no-cache" }
        var out = "HTTP/1.1 \(resp.status) \(resp.reason)\r\n"
        for (k, v) in resp.headers { out += "\(k): \(v)\r\n" }
        out += "\r\n"
        var data = Data(out.utf8)
        if req.method != "HEAD" { data.append(resp.body) }
        conn.send(content: data, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }
}

/// Server side of RFC 6455. All callbacks run on the connection's queue.
final class WebSocket {
    private let conn: NWConnection
    let queue: DispatchQueue
    private var buffer: Data
    private var fragments = Data()
    private var fragmentOpcode: UInt8 = 0
    private var closed = false
    private var keepAlive: WebSocket?
    /// Whatever handles this socket (the phone session); released when the socket closes.
    var owner: AnyObject?

    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClose: (() -> Void)?

    /// Bytes handed to the network but not yet sent. Used to drop video when the link is slow.
    private(set) var pendingBytes = 0

    private static let maxMessage = 4 * 1024 * 1024

    init(conn: NWConnection, queue: DispatchQueue, initial: Data) {
        self.conn = conn
        self.queue = queue
        self.buffer = initial
    }

    func start() {
        keepAlive = self
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.didClose()
            default: break
            }
        }
        parse()
        read()
    }

    private func read() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            self.parse()
            if error != nil || done { self.close() } else if !self.closed { self.read() }
        }
    }

    private func parse() {
        while !closed {
            let b = [UInt8](buffer.prefix(14))
            guard b.count >= 2 else { return }
            let fin = b[0] & 0x80 != 0
            let opcode = b[0] & 0x0F
            let masked = b[1] & 0x80 != 0
            var len = Int(b[1] & 0x7F)
            var offset = 2
            if len == 126 {
                guard b.count >= 4 else { return }
                len = Int(b[2]) << 8 | Int(b[3])
                offset = 4
            } else if len == 127 {
                guard b.count >= 10 else { return }
                var l: UInt64 = 0
                for i in 2..<10 { l = l << 8 | UInt64(b[i]) }
                guard l <= UInt64(Self.maxMessage) else { return close() }
                len = Int(l)
                offset = 10
            }
            guard masked else { return close() } // clients must mask
            guard len <= Self.maxMessage else { return close() }
            guard buffer.count >= offset + 4 + len else { return }
            let start = buffer.startIndex
            let mask = [UInt8](buffer[(start + offset)..<(start + offset + 4)])
            var payload = [UInt8](buffer[(start + offset + 4)..<(start + offset + 4 + len)])
            for i in 0..<payload.count { payload[i] ^= mask[i & 3] }
            buffer.removeSubrange(start..<(start + offset + 4 + len))
            handleFrame(fin: fin, opcode: opcode, payload: Data(payload))
        }
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x0: // continuation
            fragments.append(payload)
            guard fragments.count <= Self.maxMessage else { return close() }
            if fin { deliver(opcode: fragmentOpcode, payload: fragments); fragments = Data() }
        case 0x1, 0x2:
            if fin { deliver(opcode: opcode, payload: payload) } else { fragmentOpcode = opcode; fragments = payload }
        case 0x8: close()
        case 0x9: sendFrame(opcode: 0xA, payload: payload)
        default: break // pong and unknown
        }
    }

    private func deliver(opcode: UInt8, payload: Data) {
        if opcode == 0x1 {
            if let s = String(data: payload, encoding: .utf8) { onText?(s) }
        } else {
            onBinary?(payload)
        }
    }

    func send(text: String) { sendFrame(opcode: 0x1, payload: Data(text.utf8)) }
    func send(binary: Data) { sendFrame(opcode: 0x2, payload: binary) }

    func send(json: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let s = String(data: data, encoding: .utf8) {
            send(text: s)
        }
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        guard !closed else { return }
        var header = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 {
            header.append(UInt8(n))
        } else if n <= 0xFFFF {
            header.append(contentsOf: [126, UInt8(n >> 8), UInt8(n & 0xFF)])
        } else {
            header.append(127)
            for i in (0..<8).reversed() { header.append(UInt8((UInt64(n) >> (UInt64(i) * 8)) & 0xFF)) }
        }
        let size = header.count + n
        pendingBytes += size
        conn.batch {
            conn.send(content: header, completion: .idempotent)
            conn.send(content: payload, completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.pendingBytes -= size }
            })
        }
    }

    func close() {
        guard !closed else { return }
        sendFrame(opcode: 0x8, payload: Data())
        closed = true
        conn.cancel()
        didClose()
    }

    private func didClose() {
        closed = true
        if let cb = onClose { onClose = nil; cb() }
        onText = nil
        onBinary = nil
        owner = nil
        keepAlive = nil
    }
}
