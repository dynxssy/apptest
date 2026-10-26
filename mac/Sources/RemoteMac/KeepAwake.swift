import Foundation
import IOKit.pwr_mgt

/// Built-in caffeinate: holds IOKit power assertions instead of running /usr/bin/caffeinate.
/// Main-thread only.
final class KeepAwake {
    enum Mode: String {
        case off, connected, always
    }

    private(set) var mode: Mode
    private(set) var keepDisplay: Bool
    /// When set, the Mac stays awake until this time and then drops back to `mode`.
    private(set) var until: Date?
    var connectedPhones = 0 { didSet { refresh() } }
    var streaming = false { didSet { refresh() } }
    var onChange: (() -> Void)?

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var timer: Timer?

    init() {
        mode = Mode(rawValue: Config.shared.settings.keepAwakeMode) ?? .connected
        keepDisplay = Config.shared.settings.keepDisplayAwake
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func set(mode: Mode, keepDisplay: Bool? = nil, hours: Double? = nil) {
        if let hours, hours > 0 {
            until = Date().addingTimeInterval(hours * 3600)
        } else {
            self.mode = mode
            until = nil
            Config.shared.update { $0.keepAwakeMode = mode.rawValue }
        }
        if let keepDisplay {
            self.keepDisplay = keepDisplay
            Config.shared.update { $0.keepDisplayAwake = keepDisplay }
        }
        refresh()
    }

    var isAwakeHeld: Bool { systemAssertion != 0 }

    var state: [String: Any] {
        var s: [String: Any] = ["mode": mode.rawValue, "display": keepDisplay, "active": isAwakeHeld]
        if let until { s["until"] = Int(until.timeIntervalSince1970 * 1000) }
        return s
    }

    func refresh() {
        if let u = until, u < Date() { until = nil }
        let wantSystem = until != nil || mode == .always || (mode == .connected && connectedPhones > 0) || streaming
        // While a phone is watching, the display has to stay on or the picture freezes.
        let wantDisplay = (wantSystem && keepDisplay) || streaming
        let changed = (wantSystem != (systemAssertion != 0)) || (wantDisplay != (displayAssertion != 0))
        hold(&systemAssertion, kIOPMAssertionTypePreventUserIdleSystemSleep, wantSystem)
        hold(&displayAssertion, kIOPMAssertionTypePreventUserIdleDisplaySleep, wantDisplay)
        if changed { onChange?() }
    }

    private func hold(_ id: inout IOPMAssertionID, _ type: String, _ want: Bool) {
        if want && id == 0 {
            var newID: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "RemoteMac keeps this Mac reachable" as CFString, &newID)
            if r == kIOReturnSuccess { id = newID }
        } else if !want && id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }

    /// Turns the display on (e.g. when a phone connects to a sleeping screen).
    static func wakeDisplay() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("RemoteMac phone connected" as CFString, kIOPMUserActiveLocal, &id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { IOPMAssertionRelease(id) }
    }
}
