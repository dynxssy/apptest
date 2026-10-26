import Foundation
import Security

/// Settings and secrets live in ~/Library/Application Support/RemoteMac (never in the repo).
final class Config {
    static let shared = Config()

    let dir: URL
    private let settingsURL: URL
    private let tokenURL: URL

    struct Settings: Codable {
        var httpsPort: UInt16 = 8443
        var setupPort: UInt16 = 8080
        /// "off", "connected" (only while a phone is connected) or "always"
        var keepAwakeMode: String = "connected"
        var keepDisplayAwake: Bool = false
        /// Address the phone reaches over WireGuard; added to the TLS certificate.
        var tunnelAddress: String = "10.66.0.1"
    }

    private(set) var settings = Settings()
    private(set) var token: String = ""

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("RemoteMac", isDirectory: true)
        settingsURL = dir.appendingPathComponent("settings.json")
        tokenURL = dir.appendingPathComponent("token")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: settingsURL),
           let s = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = s
        } else {
            save()
        }
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 24 {
            token = t
        } else {
            resetToken()
        }
    }

    func update(_ change: (inout Settings) -> Void) {
        change(&settings)
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    /// Creates a new pairing token. Every paired phone has to scan the new QR code afterwards.
    func resetToken() {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
    }

    /// Constant-time comparison so the token can't be guessed byte by byte.
    func checkToken(_ candidate: String) -> Bool {
        let a = Array(candidate.utf8), b = Array(token.utf8)
        guard a.count == b.count, !b.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Folder holding the phone web app: inside the .app bundle, or ../web when run from the repo.
    var webRoot: URL {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("index.html").path) {
            return res
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("web")
    }
}

enum Log {
    static func info(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write("[\(ts)] \(msg)\n".data(using: .utf8)!)
    }
}
