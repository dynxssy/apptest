import AppKit

/// Small quality-of-life actions the phone can trigger.
enum SystemActions {
    static func clipboardText() -> String {
        onMain { NSPasteboard.general.string(forType: .string) ?? "" }
    }

    static func setClipboard(_ text: String) {
        onMain {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Returns false for unknown action names.
    static func run(_ name: String, input: InputController) -> Bool {
        switch name {
        case "lock":
            input.press(key: "q", mods: ["cmd", "ctrl"])
        case "displaySleep":
            shell("/usr/bin/pmset", ["displaysleepnow"])
        case "volumeUp":
            osascript("set volume output volume ((output volume of (get volume settings)) + 6)")
        case "volumeDown":
            osascript("set volume output volume ((output volume of (get volume settings)) - 6)")
        case "mute":
            osascript("set volume output muted (not (output muted of (get volume settings)))")
        case "missionControl":
            input.press(key: "up", mods: ["ctrl"])
        case "spotlight":
            input.press(key: "space", mods: ["cmd"])
        case "appSwitcher":
            input.press(key: "tab", mods: ["cmd"])
        case "showDesktop":
            input.press(key: "f11", mods: [])
        default:
            return false
        }
        return true
    }

    private static func osascript(_ script: String) {
        shell("/usr/bin/osascript", ["-e", script])
    }

    private static func shell(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    private static func onMain<T>(_ f: () -> T) -> T {
        Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f)
    }
}
