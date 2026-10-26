import AppKit
import AVFoundation

/// Owns the servers, capture pipelines and connected phones. Main-thread object.
final class AppCore {
    let certs = Certificates(baseDir: Config.shared.dir)
    let screen = ScreenStreamer()
    let camera = CameraStreamer()
    let input = InputController()
    let keepAwake = KeepAwake()
    let limiter = AuthLimiter() // used on the web queue

    private var https: WebServer?
    private var setup: WebServer?
    private(set) var sessions: [ObjectIdentifier: ClientSession] = [:]
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    var httpsPort: UInt16 { Config.shared.settings.httpsPort }
    var setupPort: UInt16 { Config.shared.settings.setupPort }

    /// Addresses a phone can use, best first: WireGuard tunnel, then LAN, then Bonjour name.
    var addresses: [String] {
        let tunnel = Config.shared.settings.tunnelAddress
        var list = NetworkInfo.localIPv4()
        list.sort { a, b in a == tunnel ? true : b == tunnel ? false : a < b }
        if !list.contains(tunnel) { list.append(tunnel) }
        list.append(NetworkInfo.bonjourName)
        return list
    }

    func start() {
        screen.onActiveChanged = { [weak self] active in self?.keepAwake.streaming = active }
        screen.onError = { [weak self] msg in self?.report(msg) }
        camera.onError = { [weak self] msg in DispatchQueue.main.async { self?.report(msg) } }
        keepAwake.onChange = { [weak self] in self?.broadcastState() }

        do {
            let identity = try certs.identity(addresses: addresses + ["localhost", "127.0.0.1"])
            https = try WebServer(port: httpsPort, identity: identity, router: { [weak self] req in
                self?.routeApp(req) ?? .notFound
            }, onWebSocket: { [weak self] ws, req in
                guard let self, req.path == "/ws" else { return ws.close() }
                ws.owner = ClientSession(ws: ws, remote: req.remote, core: self)
            })
            setup = try WebServer(port: setupPort, identity: nil, router: { [weak self] req in
                self?.routeSetup(req) ?? .notFound
            }, onWebSocket: nil)
            https?.start()
            setup?.start()
        } catch {
            report("Couldn't start the server: \(error.localizedDescription)")
        }
    }

    private func report(_ msg: String) {
        lastError = msg
        Log.info(msg)
        for s in sessions.values { s.send(json: ["t": "error", "msg": msg]) }
        onChange?()
    }

    // MARK: Sessions

    func sessionStarted(_ s: ClientSession) {
        sessions[ObjectIdentifier(s)] = s
        keepAwake.connectedPhones = sessions.count
        onChange?()
    }

    func sessionEnded(_ s: ClientSession) {
        sessions.removeValue(forKey: ObjectIdentifier(s))
        keepAwake.connectedPhones = sessions.count
        onChange?()
    }

    func disconnectAll() {
        for s in sessions.values { s.ws.queue.async { s.ws.close() } }
    }

    /// Changes with every install, so an open phone page knows to reload the new web app.
    static let build: String = {
        let exe = Bundle.main.executableURL?.path ?? ""
        let date = (try? FileManager.default.attributesOfItem(atPath: exe)[.modificationDate] as? Date) ?? Date()
        return String(Int(date.timeIntervalSince1970))
    }()

    func helloMessage() -> [String: Any] {
        let displays: [[String: Any]] = orderedScreens().enumerated().map { i, scr in
            ["index": i, "name": scr.localizedName, "w": Int(scr.frame.width), "h": Int(scr.frame.height)]
        }
        return [
            "t": "hello",
            "build": Self.build,
            "name": Host.current().localizedName ?? "Mac",
            "displays": displays,
            "cameras": CameraStreamer.list(),
            "perms": [
                "screen": CGPreflightScreenCaptureAccess(),
                "accessibility": InputController.isTrusted,
                "camera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            ],
            "keepAwake": keepAwake.state,
            "error": lastError ?? "",
        ]
    }

    /// Same order as ScreenStreamer uses: main display first, then left to right.
    private func orderedScreens() -> [NSScreen] {
        NSScreen.screens.sorted { a, b in
            if a == NSScreen.screens.first { return true }
            if b == NSScreen.screens.first { return false }
            return a.frame.minX < b.frame.minX
        }
    }

    private func broadcastState() {
        let msg: [String: Any] = ["t": "state", "keepAwake": keepAwake.state]
        for s in sessions.values { s.send(json: msg) }
        onChange?()
    }

    // MARK: HTTP routes

    private func routeApp(_ req: HTTPRequest) -> HTTPResponse {
        if req.path == "/ca.mobileconfig" || req.path == "/ca.cer" { return routeSetup(req) }
        var res = StaticFiles.serve(root: Config.shared.webRoot, path: req.path)
        if req.path == "/" || req.path == "/index.html", let html = String(data: res.body, encoding: .utf8) {
            // Versioned asset links, so iOS never keeps an old app.js/style.css after an update.
            let v = Self.build
            res.body = Data(html.replacingOccurrences(of: "href=\"style.css\"", with: "href=\"style.css?v=\(v)\"")
                .replacingOccurrences(of: "src=\"app.js\"", with: "src=\"app.js?v=\(v)\"").utf8)
            res.headers["Cache-Control"] = "no-store"
        }
        return res
    }

    /// Plain-HTTP helper: only hands out the CA certificate, so a phone can trust the HTTPS app.
    private func routeSetup(_ req: HTTPRequest) -> HTTPResponse {
        switch req.path {
        case "/ca.mobileconfig":
            guard let data = certs.mobileConfig() else { return .notFound }
            return HTTPResponse(headers: ["Content-Type": "application/x-apple-aspen-config",
                                          "Content-Disposition": "attachment; filename=RemoteMac.mobileconfig"],
                                body: data)
        case "/ca.cer":
            guard let data = try? Data(contentsOf: certs.caDER) else { return .notFound }
            return HTTPResponse(headers: ["Content-Type": "application/x-x509-ca-cert"], body: data)
        case "/":
            let host = (req.headers["host"] ?? addresses[0]).split(separator: ":").first.map(String.init) ?? addresses[0]
            return .text(SetupPage.html(host: host, httpsPort: httpsPort), type: "text/html; charset=utf-8")
        default:
            let host = (req.headers["host"] ?? addresses[0]).split(separator: ":").first.map(String.init) ?? addresses[0]
            return .redirect("https://\(host):\(httpsPort)/")
        }
    }

    func pairingURL(address: String) -> String {
        "https://\(address):\(httpsPort)/#t=\(Config.shared.token)"
    }
}

enum StaticFiles {
    static let types: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json", "webmanifest": "application/manifest+json",
        "png": "image/png", "svg": "image/svg+xml", "ico": "image/x-icon",
    ]

    static func serve(root: URL, path: String) -> HTTPResponse {
        let rel = path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
        let file = root.appendingPathComponent(rel).standardizedFileURL
        let rootPath = root.standardizedFileURL.path + "/"
        guard file.path.hasPrefix(rootPath), let data = try? Data(contentsOf: file) else { return .notFound }
        let type = types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        return HTTPResponse(headers: ["Content-Type": type], body: data)
    }
}

enum SetupPage {
    static func html(host: String, httpsPort: UInt16) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>RemoteMac setup</title>
        <style>
        body{font:17px -apple-system,system-ui,sans-serif;max-width:560px;margin:0 auto;padding:24px 16px;
        background:#0f1115;color:#e8eaed}a.btn{display:block;text-align:center;background:#3d7bfd;color:#fff;
        padding:14px;border-radius:12px;text-decoration:none;font-weight:600;margin:12px 0}li{margin:10px 0}
        small{color:#9aa0a6}</style></head><body>
        <h1>RemoteMac setup</h1>
        <p>Do this once on your iPhone so it can talk to your Mac securely.</p>
        <ol>
        <li>Tap the button below and choose <b>Allow</b>.
        <a class="btn" href="/ca.mobileconfig">Install RemoteMac certificate</a></li>
        <li>Open <b>Settings</b> &gt; <b>Profile Downloaded</b> and tap <b>Install</b>.</li>
        <li>Open <b>Settings</b> &gt; <b>General</b> &gt; <b>About</b> &gt; <b>Certificate Trust Settings</b>
        and switch on <b>RemoteMac Local CA</b>.</li>
        <li>Scan the pairing QR code shown on your Mac (menu bar icon &gt; Pair a phone), then in Safari tap
        <b>Share</b> &gt; <b>Add to Home Screen</b>.</li>
        </ol>
        <a class="btn" href="https://\(host):\(httpsPort)/">Open RemoteMac</a>
        <small>The certificate was created on your Mac and only lets this phone trust your Mac.</small>
        </body></html>
        """
    }
}
