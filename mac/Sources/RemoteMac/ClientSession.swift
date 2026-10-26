import AppKit
import AVFoundation

/// Failed-login throttle per IP address. Used on the web server queue only.
final class AuthLimiter {
    private var failures: [String: (count: Int, until: Date)] = [:]

    func isLocked(_ ip: String) -> Bool {
        guard let f = failures[ip] else { return false }
        if f.until < Date() && f.count >= 5 { failures[ip] = nil; return false }
        return f.count >= 5 && f.until > Date()
    }

    func fail(_ ip: String) {
        let count = (failures[ip]?.count ?? 0) + 1
        failures[ip] = (count, Date().addingTimeInterval(count >= 5 ? 300 : 60))
    }

    func succeed(_ ip: String) { failures[ip] = nil }
}

/// One connected phone. Everything runs on the WebSocket's queue; capture threads hop onto it.
final class ClientSession: MediaSink {
    let ws: WebSocket
    let remote: String
    private unowned let core: AppCore
    private var authed = false
    private var watching: Set<StreamID> = []
    private var waitingForKey: Set<StreamID> = [.screen, .camera]
    private var lastKeyRequest: [StreamID: TimeInterval] = [:]
    private var lastCongestionNotice: TimeInterval = 0
    private var displayIndex = 0

    // Unsent bytes allowed before video frames are skipped (keeps latency low on mobile data).
    private let softLimit = 256 * 1024
    private let lowWater = 64 * 1024
    private let audioLimit = 2 * 1024 * 1024

    init(ws: WebSocket, remote: String, core: AppCore) {
        self.ws = ws
        self.remote = remote
        self.core = core
        ws.onText = { [weak self] text in self?.handle(text) }
        ws.onBinary = { _ in }
        ws.onClose = { [weak self] in self?.closed() }
        ws.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            if let self, !self.authed { self.ws.close() }
        }
    }

    private func closed() {
        core.screen.unsubscribe(self)
        core.camera.unsubscribe(self)
        if authed {
            core.input.releaseAll()
            DispatchQueue.main.async { self.core.sessionEnded(self) }
        }
    }

    // MARK: - Incoming

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = msg["t"] as? String else { return }

        if !authed {
            guard t == "auth" else { return ws.close() }
            if core.limiter.isLocked(remote) {
                ws.send(json: ["t": "denied", "reason": "Too many wrong attempts. Try again in a few minutes."])
                return ws.close()
            }
            guard let token = msg["token"] as? String, Config.shared.checkToken(token) else {
                core.limiter.fail(remote)
                Log.info("rejected login from \(remote)")
                ws.send(json: ["t": "denied", "reason": "Wrong pairing code. Scan the QR code on the Mac again."])
                return ws.close()
            }
            core.limiter.succeed(remote)
            authed = true
            Log.info("phone connected from \(remote)")
            DispatchQueue.main.async {
                self.core.sessionStarted(self)
                KeepAwake.wakeDisplay()
                let hello = self.core.helloMessage()
                self.ws.queue.async { self.ws.send(json: hello) }
            }
            return
        }

        let bounds = core.screen.displayBounds
        switch t {
        case "ping":
            ws.send(json: ["t": "pong", "ts": msg["ts"] ?? 0])

        case "screen":
            if bool(msg["on"]) {
                displayIndex = int(msg["display"]) ?? 0
                watching.insert(.screen)
                waitingForKey.insert(.screen)
                core.screen.subscribe(self, display: displayIndex,
                                      quality: .named(msg["quality"] as? String), audio: bool(msg["audio"]))
            } else {
                watching.remove(.screen)
                core.screen.unsubscribe(self)
            }

        case "audio":
            core.screen.setAudio(self, enabled: bool(msg["on"]))

        case "camera":
            if bool(msg["on"]) {
                watching.insert(.camera)
                waitingForKey.insert(.camera)
                core.camera.subscribe(self, deviceID: msg["id"] as? String)
            } else {
                watching.remove(.camera)
                core.camera.unsubscribe(self)
            }

        case "keyframe":
            requestKeyframe(StreamID(rawValue: UInt8(clamping: int(msg["s"]) ?? 0)) ?? .screen, force: true)

        case "move":
            if let x = double(msg["x"]), let y = double(msg["y"]) { core.input.move(x: x, y: y, in: bounds) }

        case "rel":
            if let dx = double(msg["dx"]), let dy = double(msg["dy"]) {
                core.input.moveBy(dx: dx, dy: dy, in: bounds) { [weak self] x, y in
                    guard let self else { return }
                    self.ws.queue.async { self.ws.send(json: ["t": "cursor", "x": x, "y": y]) }
                }
            }

        case "button":
            core.input.button(int(msg["b"]) ?? 0, down: bool(msg["down"]))

        case "click":
            core.input.click(int(msg["b"]) ?? 0, count: int(msg["n"]) ?? 1)

        case "scroll":
            core.input.scroll(dx: double(msg["dx"]) ?? 0, dy: double(msg["dy"]) ?? 0)

        case "text":
            if let s = msg["s"] as? String, s.count <= 10_000 { core.input.type(text: s) }

        case "key":
            if let k = msg["k"] as? String { core.input.press(key: k, mods: msg["mods"] as? [String] ?? []) }

        case "mod":
            if let k = msg["k"] as? String { core.input.modifier(k, down: bool(msg["down"])) }

        case "keepAwake":
            let mode = KeepAwake.Mode(rawValue: msg["mode"] as? String ?? "") ?? .connected
            let display = msg["display"].map { bool($0) }
            let hours = double(msg["hours"])
            DispatchQueue.main.async { self.core.keepAwake.set(mode: mode, keepDisplay: display, hours: hours) }

        case "clipboard":
            if (msg["a"] as? String) == "set", let s = msg["text"] as? String {
                SystemActions.setClipboard(s)
            } else {
                let text = SystemActions.clipboardText()
                ws.send(json: ["t": "clipboard", "text": text])
            }

        case "action":
            if let name = msg["name"] as? String, !SystemActions.run(name, input: core.input) {
                ws.send(json: ["t": "error", "msg": "Unknown action \(name)"])
            }

        default:
            break
        }
    }

    // MARK: - Outgoing media

    func videoConfig(_ stream: StreamID, _ config: H264Encoder.Config) {
        ws.queue.async {
            guard self.watching.contains(stream) else { return }
            self.waitingForKey.insert(stream)
            self.ws.send(json: Wire.config(stream, config))
        }
    }

    func videoFrame(_ stream: StreamID, _ frame: H264Encoder.Frame) {
        ws.queue.async { self.deliver(stream, frame) }
    }

    func audioPacket(_ packet: Data) {
        ws.queue.async {
            guard self.authed, self.ws.pendingBytes < self.audioLimit else { return }
            self.ws.send(binary: packet)
        }
    }

    private func deliver(_ stream: StreamID, _ frame: H264Encoder.Frame) {
        guard authed, watching.contains(stream) else { return }
        let pending = ws.pendingBytes
        if waitingForKey.contains(stream) {
            if frame.isKey && pending < softLimit {
                waitingForKey.remove(stream)
                ws.send(binary: Wire.video(stream, frame))
            } else if pending < lowWater {
                requestKeyframe(stream, force: false)
            }
            return
        }
        if pending > softLimit {
            // The link can't keep up: skip until it drains, then restart from a fresh keyframe.
            waitingForKey.insert(stream)
            noteCongestion()
            return
        }
        ws.send(binary: Wire.video(stream, frame))
    }

    private func requestKeyframe(_ stream: StreamID, force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, let last = lastKeyRequest[stream], now - last < 1.0 { return }
        lastKeyRequest[stream] = now
        waitingForKey.insert(stream)
        switch stream {
        case .screen: core.screen.requestKeyframe()
        case .camera: core.camera.requestKeyframe()
        }
    }

    private func noteCongestion() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCongestionNotice > 3 else { return }
        lastCongestionNotice = now
        ws.send(json: ["t": "congested"])
    }

    func send(json: [String: Any]) {
        ws.queue.async { if self.authed { self.ws.send(json: json) } }
    }

    // MARK: - JSON helpers

    private func double(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    private func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    private func bool(_ v: Any?) -> Bool { (v as? NSNumber)?.boolValue ?? false }
}
