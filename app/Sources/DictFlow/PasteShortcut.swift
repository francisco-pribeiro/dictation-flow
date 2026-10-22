import AppKit

/// A modifier+key chord (letter or digit) that re-pastes the last transcript. Stored as e.g. "cmd+ctrl+z".
struct PasteShortcut: Equatable {
    let keyCode: Int64
    let modifiers: UInt64   // CGEventFlags: command 0x100000, control 0x40000, option 0x80000, shift 0x20000

    static let cmd: UInt64 = 0x100000, ctrl: UInt64 = 0x40000, opt: UInt64 = 0x80000, shift: UInt64 = 0x20000
    static let modMask = cmd | ctrl | opt | shift
    static let escKeyCode: Int64 = 53

    // ANSI key codes for letters and digits.
    static let keys: [String: Int64] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
    private static let mods: [(String, String, UInt64)] = [("ctrl", "Ctrl", ctrl), ("opt", "Opt", opt), ("shift", "Shift", shift), ("cmd", "Cmd", cmd)]

    static let defaultShortcut = PasteShortcut(keyCode: 6, modifiers: cmd | ctrl)   // Cmd+Ctrl+Z
    static let presets: [PasteShortcut] = [
        defaultShortcut,
        PasteShortcut(keyCode: 9, modifiers: cmd | ctrl),   // Cmd+Ctrl+V
        PasteShortcut(keyCode: 9, modifiers: ctrl | opt),   // Ctrl+Opt+V
    ]

    private var keyName: String? { Self.keys.first { $0.value == keyCode }?.key }

    var name: String {
        (Self.mods.filter { modifiers & $0.2 != 0 }.map { $0.0 } + [keyName ?? "?"]).joined(separator: "+")
    }
    var label: String {
        (Self.mods.filter { modifiers & $0.2 != 0 }.map { $0.1 } + [(keyName ?? "?").uppercased()]).joined(separator: "+")
    }

    /// Needs a known key and at least one of Cmd, Ctrl, Opt (Shift alone would hijack typing).
    static func parse(_ s: String?) -> PasteShortcut? {
        guard let s, !s.isEmpty else { return nil }
        let parts = s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let code = keys[parts.last!] else { return nil }
        var m: UInt64 = 0
        for p in parts.dropLast() {
            guard let flag = mods.first(where: { $0.0 == p })?.2, m & flag == 0 else { return nil }
            m |= flag
        }
        guard m & (cmd | ctrl | opt) != 0 else { return nil }
        return PasteShortcut(keyCode: code, modifiers: m)
    }

    /// settings.json over the default. An unparseable value falls back to the default.
    static func resolve(settings: Settings) -> PasteShortcut { parse(settings.pasteShortcut) ?? defaultShortcut }

    func matches(keyCode k: Int64, flags: UInt64) -> Bool { k == keyCode && flags & Self.modMask == modifiers }

    enum CaptureResult: Equatable { case none, captured(PasteShortcut), cancelled }

    /// What a key-down means while recording a new shortcut: Esc cancels, modifier+letter/digit is captured.
    static func capture(keyCode: Int64, flags: UInt64) -> CaptureResult {
        if keyCode == escKeyCode { return .cancelled }
        guard keys.values.contains(keyCode), flags & (cmd | ctrl | opt) != 0 else { return .none }
        return .captured(PasteShortcut(keyCode: keyCode, modifiers: flags & modMask))
    }

    static func selfTest() -> Bool {
        var ok = true
        func check(_ c: Bool, _ m: String) { if !c { ok = false; print("FAIL: \(m)") } }
        let d = defaultShortcut
        check(d.name == "ctrl+cmd+z" && d.label == "Ctrl+Cmd+Z", "default name/label: \(d.name) \(d.label)")
        check(parse(d.name) == d, "name roundtrip")
        check(parse("CMD+Ctrl+Z") == d, "parse ignores case and order")
        for p in presets { check(parse(p.name) == p, "preset roundtrip \(p.name)") }
        for bad in ["", "z", "cmd", "cmd+", "shift+z", "cmd+cmd+z", "cmd+f12", "foo+z", "cmd+zz"] {
            check(parse(bad) == nil, "rejects '\(bad)'")
        }
        check(parse(nil) == nil, "nil")
        var s = Settings(); check(resolve(settings: s) == d, "default when unset")
        s.pasteShortcut = "ctrl+opt+v"; check(resolve(settings: s) == presets[2], "settings win")
        s.pasteShortcut = "garbage"; check(resolve(settings: s) == d, "garbage falls back")

        let cz: UInt64 = 0x100000 | 0x40000
        check(d.matches(keyCode: 6, flags: cz), "match")
        check(d.matches(keyCode: 6, flags: cz | 0x100), "match ignores non-modifier flag bits")
        check(!d.matches(keyCode: 6, flags: 0x100000), "Cmd+Z (undo) not swallowed")
        check(!d.matches(keyCode: 6, flags: cz | 0x20000), "extra Shift not a match")
        check(!d.matches(keyCode: 7, flags: cz), "other key not a match")

        check(capture(keyCode: 53, flags: 0) == .cancelled, "esc cancels")
        check(capture(keyCode: 9, flags: 0x100000 | 0x80000) == .captured(PasteShortcut(keyCode: 9, modifiers: 0x180000)), "Cmd+Opt+V captured")
        check(capture(keyCode: 9, flags: 0) == .none, "no modifier ignored")
        check(capture(keyCode: 9, flags: 0x20000) == .none, "shift only ignored")
        check(capture(keyCode: 36, flags: 0x100000) == .none, "return key not accepted")
        return ok
    }
}

/// Global shortcut via an active (swallowing) CGEventTap on its own thread, kept apart from the push-to-talk
/// tap so a failure here never disables dictation. Callbacks fire on the main queue.
final class PasteShortcutMonitor {
    var onFire: () -> Void = {}
    var onCaptured: (PasteShortcut) -> Void = { _ in }
    var onCaptureCancelled: () -> Void = {}

    private let lock = NSLock()
    private var shortcut: PasteShortcut
    private var capturing = false
    private var swallowedUp: Int64?   // key code whose key-up we must swallow too
    private var tap: CFMachPort?
    private var thread: Thread?

    init(shortcut: PasteShortcut) { self.shortcut = shortcut }

    func setShortcut(_ s: PasteShortcut) { lock.lock(); shortcut = s; lock.unlock() }
    func beginCapture() { lock.lock(); capturing = true; lock.unlock() }
    func endCapture() { lock.lock(); capturing = false; lock.unlock() }

    /// Returns false when the tap cannot be created (needs Accessibility, and Input Monitoring).
    func start() -> Bool {
        if thread != nil { return true }
        let events: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let swallow = Unmanaged<PasteShortcutMonitor>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: events, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        let th = Thread {
            let src = CFMachPortCreateRunLoopSource(nil, t, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.name = "dictflow-paste-shortcut"
        thread = th
        th.start()
        return true
    }

    /// True when the event must not reach the focused app.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        lock.lock()
        let sc = shortcut, cap = capturing
        let pendingUp = swallowedUp
        if type == .keyUp, pendingUp == code { swallowedUp = nil }
        lock.unlock()
        if type == .keyUp { return pendingUp == code }

        let flags = event.flags.rawValue
        if cap {
            switch PasteShortcut.capture(keyCode: code, flags: flags) {
            case .captured(let s):
                endCapture(); markSwallowed(code)
                DispatchQueue.main.async { self.onCaptured(s) }
                return true
            case .cancelled:
                endCapture(); markSwallowed(code)
                DispatchQueue.main.async { self.onCaptureCancelled() }
                return true
            case .none: return false
            }
        }
        guard sc.matches(keyCode: code, flags: flags) else { return false }
        markSwallowed(code)
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { DispatchQueue.main.async { self.onFire() } }
        return true
    }

    private func markSwallowed(_ code: Int64) { lock.lock(); swallowedUp = code; lock.unlock() }
}
