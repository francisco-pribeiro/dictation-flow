import Foundation

/// A modifier key usable as push-to-talk hotkey.
struct HotkeyKey: Equatable {
    let name: String
    let label: String
    let keyCode: Int64
    let flag: UInt64   // CGEventFlags raw value
}

enum Hotkeys {
    // CGEventFlags raw values: alternate 0x80000, command 0x100000, control 0x40000, shift 0x20000, secondaryFn 0x800000.
    static let all: [HotkeyKey] = [
        HotkeyKey(name: "rightoption", label: "Option direito", keyCode: 61, flag: 0x80000),
        HotkeyKey(name: "rightcmd", label: "Command direito", keyCode: 54, flag: 0x100000),
        HotkeyKey(name: "rightctrl", label: "Control direito", keyCode: 62, flag: 0x40000),
        HotkeyKey(name: "fn", label: "Fn", keyCode: 63, flag: 0x800000),
        HotkeyKey(name: "leftoption", label: "Option esquerdo", keyCode: 58, flag: 0x80000),
        HotkeyKey(name: "leftcmd", label: "Command esquerdo", keyCode: 55, flag: 0x100000),
        HotkeyKey(name: "leftctrl", label: "Control esquerdo", keyCode: 59, flag: 0x40000),
        HotkeyKey(name: "leftshift", label: "Shift esquerdo", keyCode: 56, flag: 0x20000),
        HotkeyKey(name: "rightshift", label: "Shift direito", keyCode: 60, flag: 0x20000),
    ]
    static let presets = Array(all.prefix(4))
    static let defaultKey = all[0]

    static func key(named name: String?) -> HotkeyKey? { all.first { $0.name == name } }
    static func key(forKeyCode code: Int64) -> HotkeyKey? { all.first { $0.keyCode == code } }

    /// settings.json over the env var over right Option. Unknown names are ignored at each level.
    static func resolve(settings: Settings, env: String?) -> HotkeyKey {
        key(named: settings.hotkey) ?? key(named: env) ?? defaultKey
    }

    static let escKeyCode: Int64 = 53

    enum CaptureResult: Equatable { case none, captured(HotkeyKey), cancelled }

    static let modifierBits: UInt64 = 0x100000 | 0x40000 | 0x80000 | 0x20000 | 0x800000
}

/// Stateful capture of a new push-to-talk key: only a clean tap counts (modifier down, then up, with no other
/// key, click or modifier in between), so Cmd+Tab, Shift+letter or Cmd+click never rebind it. Esc cancels.
struct HotkeyCapturer {
    private var pending: HotkeyKey?

    mutating func interrupt() { pending = nil }

    mutating func feed(isKeyDown: Bool, keyCode: Int64, flags: UInt64) -> Hotkeys.CaptureResult {
        if isKeyDown {
            pending = nil
            return keyCode == Hotkeys.escKeyCode ? .cancelled : .none
        }
        guard let k = Hotkeys.key(forKeyCode: keyCode) else { pending = nil; return .none }
        if flags & k.flag != 0 {
            pending = (flags & Hotkeys.modifierBits == k.flag && pending == nil) ? k : nil
            return .none
        }
        defer { pending = nil }
        return pending == k ? .captured(k) : .none
    }
}

/// ~/Library/Application Support/DictFlow/settings.json. Unknown keys are preserved so later settings survive.
struct Settings {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DictFlow/settings.json")
    }

    private(set) var values: [String: Any] = [:]

    var hotkey: String? {
        get { values["hotkey"] as? String }
        set { values["hotkey"] = newValue }
    }

    var pasteShortcut: String? {
        get { values["pasteShortcut"] as? String }
        set { values["pasteShortcut"] = newValue }
    }

    /// Opt-in chunked dictation (also DICTFLOW_CHUNKING=1). An app launched from Finder gets no shell env, so it is a setting too.
    var chunking: Bool? {
        get { values["chunking"] as? Bool }
        set { values["chunking"] = newValue }
    }

    /// DICTFLOW_CHUNKING ("1"/"0") wins over the setting; default off.
    static func chunkingEnabled(settings: Settings, env: String?) -> Bool {
        if env == "1" { return true }
        if env == "0" { return false }
        return settings.chunking ?? false
    }

    /// Missing, unreadable or corrupt file gives empty settings (defaults apply).
    static func load(from url: URL = defaultURL) -> Settings {
        var s = Settings()
        if let data = try? Data(contentsOf: url),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { s.values = obj }
        return s
    }

    func save(to url: URL = Settings.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func selfTest() -> Bool {
        var ok = true
        func check(_ c: Bool, _ m: String) { if !c { ok = false; print("FAIL: \(m)") } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictflow-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sub/settings.json")

        check(Settings.load(from: url).hotkey == nil, "missing file gives no hotkey")
        var s = Settings(); s.hotkey = "rightcmd"
        do { try s.save(to: url) } catch { check(false, "save: \(error)") }
        check(Settings.load(from: url).hotkey == "rightcmd", "roundtrip")

        // unknown keys survive a save
        try? Data(#"{"hotkey":"fn","future":{"a":1}}"#.utf8).write(to: url)
        var t = Settings.load(from: url); t.hotkey = "rightctrl"; try? t.save(to: url)
        check(Settings.load(from: url).values["future"] != nil, "unknown keys preserved")
        check(Settings.load(from: url).hotkey == "rightctrl", "update")

        // corrupt / wrong-shaped files fall back to defaults
        for bad in ["not json", "[1,2]", "", #"{"hotkey":5}"#] {
            try? Data(bad.utf8).write(to: url)
            check(Settings.load(from: url).hotkey == nil, "corrupt '\(bad)' gives defaults")
        }

        // precedence: settings > env > default; unknown names ignored
        var a = Settings(); a.hotkey = "rightctrl"
        check(Hotkeys.resolve(settings: a, env: "fn").name == "rightctrl", "settings beat env")
        check(Hotkeys.resolve(settings: Settings(), env: "fn").name == "fn", "env when no settings")
        check(Hotkeys.resolve(settings: Settings(), env: nil).name == "rightoption", "default")
        a.hotkey = "bogus"
        check(Hotkeys.resolve(settings: a, env: "rightcmd").name == "rightcmd", "bogus setting falls to env")
        check(Hotkeys.resolve(settings: a, env: "bogus").name == "rightoption", "bogus everywhere gives default")

        // chunking: off by default, env beats setting, non-bool setting ignored
        var ch = Settings()
        check(!Settings.chunkingEnabled(settings: ch, env: nil), "chunking default off")
        ch.chunking = true
        check(Settings.chunkingEnabled(settings: ch, env: nil), "chunking from settings")
        check(!Settings.chunkingEnabled(settings: ch, env: "0"), "env 0 beats setting")
        check(Settings.chunkingEnabled(settings: Settings(), env: "1"), "env 1 turns it on")
        try? Data(#"{"chunking":"yes"}"#.utf8).write(to: url)
        check(Settings.load(from: url).chunking == nil && !Settings.chunkingEnabled(settings: Settings.load(from: url), env: nil), "non-bool chunking ignored")

        // presets and key codes are unique
        check(Hotkeys.presets.map(\.name) == ["rightoption", "rightcmd", "rightctrl", "fn"], "presets")
        check(Set(Hotkeys.all.map(\.keyCode)).count == Hotkeys.all.count, "unique key codes")
        check(Set(Hotkeys.all.map(\.name)).count == Hotkeys.all.count, "unique names")

        // capture: only a clean modifier tap is accepted
        func run(_ evs: [(Bool, Int64, UInt64)]) -> Hotkeys.CaptureResult {
            var c = HotkeyCapturer(); var r = Hotkeys.CaptureResult.none
            for e in evs { r = c.feed(isKeyDown: e.0, keyCode: e.1, flags: e.2); if r != .none { return r } }
            return r
        }
        check(run([(true, 53, 0)]) == .cancelled, "esc cancels")
        check(run([(true, 12, 0)]) == .none, "letter ignored")
        check(run([(false, 62, 0x40000), (false, 62, 0)]) == .captured(Hotkeys.key(named: "rightctrl")!), "right ctrl tap captured")
        check(run([(false, 62, 0)]) == .none, "lone release ignored")
        check(run([(false, 57, 0x10000), (false, 57, 0)]) == .none, "caps lock not a hotkey")
        check(run([(false, 55, 0x100000), (true, 8, 0x100000), (false, 55, 0)]) == .none, "cmd down, C, cmd up gives none")
        check(run([(false, 56, 0x20000), (false, 56, 0)]) == .captured(Hotkeys.key(named: "leftshift")!), "lshift tap captured")
        check(run([(false, 60, 0x20000), (false, 60, 0)]) == .captured(Hotkeys.key(named: "rightshift")!), "rshift tap captured")
        check(run([(false, 55, 0x100000), (false, 56, 0x120000), (false, 56, 0x100000), (false, 55, 0)]) == .none, "two modifiers is a chord")
        var ci = HotkeyCapturer(); _ = ci.feed(isKeyDown: false, keyCode: 55, flags: 0x100000); ci.interrupt()
        check(ci.feed(isKeyDown: false, keyCode: 55, flags: 0) == .none, "mouse click interrupts")
        return ok
    }
}
