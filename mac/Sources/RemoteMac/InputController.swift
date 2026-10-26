import Foundation
import CoreGraphics
import ApplicationServices

/// Turns phone gestures into real mouse and keyboard events. Needs the Accessibility permission.
final class InputController {
    private let queue = DispatchQueue(label: "remotemac.input", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown: Set<Int> = []
    private var heldModifiers: Set<String> = []
    private var lastDown: (time: TimeInterval, button: Int, point: CGPoint, count: Int)?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Mouse

    /// Absolute move to a normalized (0...1) point on the given display.
    func move(x: Double, y: Double, in bounds: CGRect) {
        queue.async {
            let p = CGPoint(x: bounds.minX + bounds.width * min(max(x, 0), 1),
                            y: bounds.minY + bounds.height * min(max(y, 0), 1))
            self.postMove(to: p)
        }
    }

    /// Relative move in points (trackpad mode). Returns the new normalized position on `bounds`.
    func moveBy(dx: Double, dy: Double, in bounds: CGRect, reply: @escaping (Double, Double) -> Void) {
        queue.async {
            let cur = self.cursorLocation()
            let limit = Self.desktopBounds()
            let p = CGPoint(x: min(max(cur.x + dx, limit.minX), limit.maxX - 1),
                            y: min(max(cur.y + dy, limit.minY), limit.maxY - 1))
            self.postMove(to: p)
            reply(Double((p.x - bounds.minX) / bounds.width), Double((p.y - bounds.minY) / bounds.height))
        }
    }

    func cursorNormalized(in bounds: CGRect) -> (Double, Double) {
        let p = cursorLocation()
        return (Double((p.x - bounds.minX) / bounds.width), Double((p.y - bounds.minY) / bounds.height))
    }

    func button(_ button: Int, down: Bool) {
        queue.async {
            let p = self.cursorLocation()
            if down {
                let now = ProcessInfo.processInfo.systemUptime
                var count = 1
                if let last = self.lastDown, last.button == button, now - last.time < 0.45,
                   hypot(last.point.x - p.x, last.point.y - p.y) < 8 {
                    count = min(last.count + 1, 3)
                }
                self.lastDown = (now, button, p, count)
                self.buttonsDown.insert(button)
                self.postButton(button, down: true, at: p, clickCount: count)
            } else {
                self.buttonsDown.remove(button)
                self.postButton(button, down: false, at: p, clickCount: self.lastDown?.count ?? 1)
            }
        }
    }

    func click(_ button: Int, count: Int) {
        for _ in 0..<max(1, min(count, 3)) {
            self.button(button, down: true)
            self.button(button, down: false)
        }
    }

    /// Scroll in pixels; positive dy scrolls content down like a trackpad (natural scrolling).
    func scroll(dx: Double, dy: Double) {
        queue.async {
            guard let e = CGEvent(scrollWheelEvent2Source: self.source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
            e.flags = self.modifierFlags()
            e.post(tap: .cghidEventTap)
        }
    }

    private func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private static func desktopBounds() -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
    }

    private func postMove(to p: CGPoint) {
        let type: CGEventType
        let button: CGMouseButton
        if buttonsDown.contains(0) { type = .leftMouseDragged; button = .left }
        else if buttonsDown.contains(1) { type = .rightMouseDragged; button = .right }
        else if buttonsDown.contains(2) { type = .otherMouseDragged; button = .center }
        else { type = .mouseMoved; button = .left }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.flags = modifierFlags()
        e.post(tap: .cghidEventTap)
    }

    private func postButton(_ b: Int, down: Bool, at p: CGPoint, clickCount: Int) {
        let type: CGEventType
        let button: CGMouseButton
        switch b {
        case 1: type = down ? .rightMouseDown : .rightMouseUp; button = .right
        case 2: type = down ? .otherMouseDown : .otherMouseUp; button = .center
        default: type = down ? .leftMouseDown : .leftMouseUp; button = .left
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e.flags = modifierFlags()
        e.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    func type(text: String) {
        queue.async {
            // Newlines become real Return presses; everything else goes in as Unicode text.
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                if i > 0 { self.postKey(code: KeyCodes.named["enter"]!, mods: []) }
                var units = Array(line.utf16)
                while !units.isEmpty {
                    let chunk = Array(units.prefix(16))
                    units.removeFirst(chunk.count)
                    for down in [true, false] {
                        guard let e = CGEvent(keyboardEventSource: self.source, virtualKey: 0, keyDown: down) else { continue }
                        e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                        e.flags = []
                        e.post(tap: .cghidEventTap)
                    }
                }
            }
        }
    }

    /// Press a named key ("enter", "left", "c", "f5"...) with modifiers ("cmd", "shift", "alt", "ctrl", "fn").
    func press(key: String, mods: [String]) {
        queue.async {
            guard let code = KeyCodes.named[key.lowercased()] else { return }
            self.postKey(code: code, mods: Set(mods.map { $0.lowercased() }))
        }
    }

    /// Hold or release a modifier (for Cmd+Tab style combos built up over several taps).
    func modifier(_ name: String, down: Bool) {
        queue.async {
            let n = name.lowercased()
            guard let code = KeyCodes.modifiers[n] else { return }
            if down { self.heldModifiers.insert(n) } else { self.heldModifiers.remove(n) }
            guard let e = CGEvent(keyboardEventSource: self.source, virtualKey: code, keyDown: down) else { return }
            e.type = .flagsChanged
            e.flags = self.modifierFlags()
            e.post(tap: .cghidEventTap)
        }
    }

    /// Lets go of anything a phone left held when it disconnected.
    func releaseAll() {
        queue.async {
            for m in self.heldModifiers { self.modifier(m, down: false) }
            for b in self.buttonsDown { self.button(b, down: false) }
        }
    }

    private func postKey(code: CGKeyCode, mods: Set<String>) {
        let flags = modifierFlags(extra: mods)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            var f = flags
            if KeyCodes.needsFn.contains(code) { f.insert(.maskSecondaryFn) }
            e.flags = f
            e.post(tap: .cghidEventTap)
        }
    }

    private func modifierFlags(extra: Set<String> = []) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in heldModifiers.union(extra) {
            switch m {
            case "cmd", "command", "meta": f.insert(.maskCommand)
            case "shift": f.insert(.maskShift)
            case "alt", "option": f.insert(.maskAlternate)
            case "ctrl", "control": f.insert(.maskControl)
            case "fn": f.insert(.maskSecondaryFn)
            default: break
            }
        }
        return f
    }
}

enum KeyCodes {
    static let modifiers: [String: CGKeyCode] = [
        "cmd": 0x37, "shift": 0x38, "alt": 0x3A, "ctrl": 0x3B, "fn": 0x3F,
    ]

    static let named: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "enter": 0x24, "return": 0x24, "tab": 0x30, "space": 0x31, "backspace": 0x33,
            "escape": 0x35, "esc": 0x35, "delete": 0x75, "left": 0x7B, "right": 0x7C, "down": 0x7D,
            "up": 0x7E, "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
            "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        ]
        // ANSI layout positions, used for shortcuts such as Cmd+C.
        let chars: [(String, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8),
            ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17),
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25),
            ("7", 26), ("-", 27), ("8", 28), ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33),
            ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42),
            (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47), ("`", 50),
        ]
        for (k, v) in chars { m[k] = v }
        return m
    }()

    /// Arrow/navigation keys carry the fn flag when typed on a real Mac keyboard.
    static let needsFn: Set<CGKeyCode> = [0x7B, 0x7C, 0x7D, 0x7E, 0x73, 0x77, 0x74, 0x79, 0x75]
}
