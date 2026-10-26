import Foundation
import Security

/// A private certificate authority made on this Mac. The phone trusts it once (profile install),
/// after which the HTTPS page and its WebSocket work without warnings. Keys never leave the Mac.
final class Certificates {
    let dir: URL
    private let openssl = "/usr/bin/openssl" // system LibreSSL: its PKCS#12 output imports cleanly
    private let p12Password = "remotemac" // only protects the file at rest next to its own key

    var caPEM: URL { dir.appendingPathComponent("ca.pem") }
    var caDER: URL { dir.appendingPathComponent("ca.cer") }
    private var caKey: URL { dir.appendingPathComponent("ca.key") }
    private var serverKey: URL { dir.appendingPathComponent("server.key") }
    private var serverPEM: URL { dir.appendingPathComponent("server.pem") }
    private var serverP12: URL { dir.appendingPathComponent("server.p12") }
    private var sansFile: URL { dir.appendingPathComponent("server.sans") }

    init(baseDir: URL) {
        dir = baseDir.appendingPathComponent("tls", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// Makes sure the CA and a server certificate covering every current address exist,
    /// then returns the identity for the TLS listener.
    func identity(addresses: [String]) throws -> SecIdentity {
        let fm = FileManager.default
        if !fm.fileExists(atPath: caKey.path) || !fm.fileExists(atPath: caPEM.path) {
            try makeCA()
            try? fm.removeItem(at: serverP12)
        }
        let wanted = Set(addresses)
        let existing = Set(((try? String(contentsOf: sansFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init))
        if !fm.fileExists(atPath: serverP12.path) || !wanted.isSubset(of: existing) {
            // Keep old names too, so a phone on a previous address keeps working.
            try makeServerCert(sans: Array(wanted.union(existing)).sorted())
        }
        if let id = try? importP12() { return id }
        // Newer OpenSSL builds default to ciphers Security.framework can't read.
        try run(["pkcs12", "-export", "-legacy", "-inkey", serverKey.path, "-in", serverPEM.path,
                 "-certfile", caPEM.path, "-out", serverP12.path, "-passout", "pass:\(p12Password)"])
        return try importP12()
    }

    private func makeCA() throws {
        let cnf = dir.appendingPathComponent("ca.cnf")
        try """
        [req]
        distinguished_name = dn
        [dn]
        [v3_ca]
        basicConstraints = critical, CA:TRUE
        keyUsage = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        """.write(to: cnf, atomically: true, encoding: .utf8)
        try run(["genrsa", "-out", caKey.path, "2048"])
        try run(["req", "-x509", "-new", "-key", caKey.path, "-sha256", "-days", "3650",
                 "-subj", "/CN=RemoteMac Local CA (\(ProcessInfo.processInfo.hostName))",
                 "-config", cnf.path, "-extensions", "v3_ca", "-out", caPEM.path])
        try run(["x509", "-in", caPEM.path, "-outform", "der", "-out", caDER.path])
        chmod600(caKey)
    }

    private func makeServerCert(sans: [String]) throws {
        let csr = dir.appendingPathComponent("server.csr")
        let ext = dir.appendingPathComponent("server.ext")
        let altNames = sans.map { isIP($0) ? "IP:\($0)" : "DNS:\($0)" }.joined(separator: ", ")
        try """
        basicConstraints = CA:FALSE
        keyUsage = critical, digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(altNames)
        """.write(to: ext, atomically: true, encoding: .utf8)
        try run(["genrsa", "-out", serverKey.path, "2048"])
        try run(["req", "-new", "-key", serverKey.path, "-subj", "/CN=RemoteMac", "-out", csr.path])
        // iOS rejects TLS server certificates valid for more than 825 days.
        try run(["x509", "-req", "-in", csr.path, "-CA", caPEM.path, "-CAkey", caKey.path,
                 "-CAcreateserial", "-days", "800", "-sha256", "-extfile", ext.path, "-out", serverPEM.path])
        try run(["pkcs12", "-export", "-inkey", serverKey.path, "-in", serverPEM.path,
                 "-certfile", caPEM.path, "-out", serverP12.path, "-passout", "pass:\(p12Password)"])
        try sans.joined(separator: "\n").write(to: sansFile, atomically: true, encoding: .utf8)
        chmod600(serverKey)
        chmod600(serverP12)
        Log.info("TLS certificate issued for: \(sans.joined(separator: ", "))")
    }

    private func importP12() throws -> SecIdentity {
        let data = try Data(contentsOf: serverP12)
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData,
                                     [kSecImportExportPassphrase as String: p12Password] as CFDictionary,
                                     &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]],
              let first = arr.first,
              let idRef = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: "RemoteMac.TLS", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "PKCS#12 import failed (\(status))"])
        }
        return idRef as! SecIdentity
    }

    /// Configuration profile the iPhone installs to trust the CA.
    func mobileConfig() -> Data? {
        guard let der = try? Data(contentsOf: caDER) else { return nil }
        let host = ProcessInfo.processInfo.hostName
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "local.remotemac.ca",
            "PayloadUUID": stableUUID(der, salt: "profile"),
            "PayloadDisplayName": "RemoteMac (\(host))",
            "PayloadDescription": "Lets this phone open the RemoteMac app for \(host) securely.",
            "PayloadContent": [[
                "PayloadType": "com.apple.security.root",
                "PayloadVersion": 1,
                "PayloadIdentifier": "local.remotemac.ca.cert",
                "PayloadUUID": stableUUID(der, salt: "cert"),
                "PayloadDisplayName": "RemoteMac Local CA",
                "PayloadContent": der,
            ]],
        ]
        return try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    private func stableUUID(_ data: Data, salt: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in (Array(salt.utf8) + Array(data)).enumerated() { bytes[i % 16] = bytes[i % 16] &* 31 &+ b }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return NSUUID(uuidBytes: bytes).uuidString
    }

    private func isIP(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    private func chmod600(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: openssl)
        p.arguments = args
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: out, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "RemoteMac.TLS", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "openssl \(args.first ?? "") failed: \(text)"])
        }
        return text
    }
}

enum NetworkInfo {
    /// IPv4 addresses on this Mac's real interfaces (Wi-Fi, Ethernet, WireGuard utun).
    static func localIPv4() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("bridge") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("169.254.") { result.append(ip) }
                }
            }
            ptr = ifa.ifa_next
        }
        return Array(Set(result)).sorted()
    }

    static var bonjourName: String {
        let h = ProcessInfo.processInfo.hostName
        return h.hasSuffix(".local") ? h : h.split(separator: ".").first.map { "\($0).local" } ?? "localhost"
    }
}
