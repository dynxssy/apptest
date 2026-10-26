import AppKit
import AVFoundation
import CoreImage
import ServiceManagement

/// Menu bar icon: status, pairing QR, keep-awake, permissions, start at login.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let core = AppCore()
    private var statusItem: NSStatusItem!
    private var pairingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "RemoteMac")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        core.onChange = { [weak self] in self?.updateIcon() }
        core.start()
        updateIcon()

        // Ask for everything up front so the first remote session just works.
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !InputController.isTrusted { InputController.promptForAccess() }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        }
        if Config.shared.settings.keepAwakeMode != "off", SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register() // start at login by default; toggle in the menu
        }
        if core.sessions.isEmpty && !UserDefaults.standard.bool(forKey: "pairedOnce") {
            showPairing()
        }
    }

    private func updateIcon() {
        let connected = !core.sessions.isEmpty
        statusItem.button?.image = NSImage(systemSymbolName: connected ? "display.and.arrow.down" : "display",
                                           accessibilityDescription: "RemoteMac")
        if connected { UserDefaults.standard.set(true, forKey: "pairedOnce") }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let n = core.sessions.count
        menu.addItem(disabled(n == 0 ? "No phone connected" : "\(n) phone\(n == 1 ? "" : "s") connected"))
        menu.addItem(disabled("https://\(core.addresses.first ?? "?"):\(core.httpsPort)"))
        if let err = core.lastError { menu.addItem(disabled("⚠︎ \(err)")) }
        menu.addItem(.separator())
        menu.addItem(item("Pair a Phone…", #selector(showPairing)))

        let awake = NSMenuItem(title: "Keep Mac Awake", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, mode) in [("Off", KeepAwake.Mode.off), ("While a Phone Is Connected", .connected), ("Always", .always)] {
            let i = item(title, #selector(setKeepAwake(_:)))
            i.representedObject = mode.rawValue
            i.state = core.keepAwake.mode == mode && core.keepAwake.until == nil ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        let disp = item("Keep Display On Too", #selector(toggleDisplayAwake))
        disp.state = core.keepAwake.keepDisplay ? .on : .off
        sub.addItem(disp)
        sub.addItem(disabled(core.keepAwake.isAwakeHeld ? "Currently keeping the Mac awake" : "Mac may sleep normally"))
        awake.submenu = sub
        menu.addItem(awake)

        let perms = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        let psub = NSMenu()
        let p1 = item("Screen Recording", #selector(openScreenSettings))
        p1.state = CGPreflightScreenCaptureAccess() ? .on : .off
        let p2 = item("Accessibility (mouse & keyboard)", #selector(openAccessibilitySettings))
        p2.state = InputController.isTrusted ? .on : .off
        let p3 = item("Camera", #selector(openCameraSettings))
        p3.state = AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? .on : .off
        for p in [p1, p2, p3] { psub.addItem(p) }
        perms.submenu = psub
        menu.addItem(perms)

        let login = item("Start at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("New Pairing Code (unpairs phones)", #selector(resetToken)))
        menu.addItem(item("Open Data Folder", #selector(openDataFolder)))
        menu.addItem(item("Quit RemoteMac", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func setKeepAwake(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = KeepAwake.Mode(rawValue: raw) else { return }
        core.keepAwake.set(mode: mode)
    }

    @objc private func toggleDisplayAwake() {
        core.keepAwake.set(mode: core.keepAwake.mode, keepDisplay: !core.keepAwake.keepDisplay)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            Log.info("login item: \(error.localizedDescription)")
        }
    }

    @objc private func openScreenSettings() {
        CGRequestScreenCaptureAccess()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @objc private func openAccessibilitySettings() {
        InputController.promptForAccess()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openCameraSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    @objc private func resetToken() {
        Config.shared.resetToken()
        core.disconnectAll()
        UserDefaults.standard.set(false, forKey: "pairedOnce")
        pairingWindow?.close()
        pairingWindow = nil
        showPairing()
    }

    @objc private func openDataFolder() { NSWorkspace.shared.open(Config.shared.dir) }

    @objc private func quit() { NSApp.terminate(nil) }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    // MARK: Pairing window

    @objc func showPairing() {
        if let w = pairingWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Pair a Phone"
        w.isReleasedWhenClosed = false
        w.contentView = PairingView(core: core)
        w.center()
        pairingWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// QR code + the two-minute setup steps, with a picker for which address to pair on.
final class PairingView: NSView {
    private let core: AppCore
    private let qr = NSImageView()
    private let urlLabel = NSTextField(labelWithString: "")
    private let picker = NSPopUpButton()

    init(core: AppCore) {
        self.core = core
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 640))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        let tunnelUp = NetworkInfo.localIPv4().contains(Config.shared.settings.tunnelAddress)
        picker.addItems(withTitles: core.addresses.map { addr in
            guard addr == Config.shared.settings.tunnelAddress else { return "\(addr) (home network)" }
            return tunnelUp ? "\(addr) (WireGuard, works anywhere)" : "\(addr) (WireGuard, not set up yet)"
        })
        picker.target = self
        picker.action = #selector(refresh)

        let steps = NSTextField(wrappingLabelWithString: """
        1. Turn on WireGuard on the iPhone (or join the same Wi-Fi as this Mac).
        2. In Safari open  http://\(core.addresses.first ?? "?"):\(core.setupPort)  and install the certificate \
        (Settings > General > About > Certificate Trust Settings > switch it on).
        3. Scan this QR code with the iPhone camera.
        4. In Safari tap Share > Add to Home Screen.
        """)
        steps.preferredMaxLayoutWidth = 390

        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.widthAnchor.constraint(equalToConstant: 300).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 300).isActive = true
        urlLabel.isSelectable = true
        urlLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        urlLabel.lineBreakMode = .byCharWrapping
        urlLabel.preferredMaxLayoutWidth = 390

        let warn = NSTextField(wrappingLabelWithString: "This QR code is the key to your Mac. Don't share it.")
        warn.textColor = .secondaryLabelColor

        [picker, qr, urlLabel, steps, warn].forEach(stack.addArrangedSubview)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func refresh() {
        let addr = core.addresses[max(0, picker.indexOfSelectedItem)]
        let url = core.pairingURL(address: addr)
        urlLabel.stringValue = url
        qr.image = Self.qrImage(url)
    }

    static func qrImage(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
