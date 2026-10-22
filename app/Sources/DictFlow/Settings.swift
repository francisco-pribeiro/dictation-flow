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

    /// Decides what a key event means while recording a new hotkey. Modifier-only: a modifier key going down
    /// (its flag set) is captured; Esc cancels; everything else is ignored.
    static func capture(isKeyDown: Bool, keyCode: Int64, flags: UInt64) -> CaptureResult {
        if isKeyDown { return keyCode == escKeyCode ? .cancelled : .none }
        guard let k = key(forKeyCode: keyCode), flags & k.flag != 0 else { return .none }
        return .captured(k)
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

        // presets and key codes are unique
        check(Hotkeys.presets.map(\.name) == ["rightoption", "rightcmd", "rightctrl", "fn"], "presets")
        check(Set(Hotkeys.all.map(\.keyCode)).count == Hotkeys.all.count, "unique key codes")
        check(Set(Hotkeys.all.map(\.name)).count == Hotkeys.all.count, "unique names")

        // capture state machine
        check(Hotkeys.capture(isKeyDown: true, keyCode: 53, flags: 0) == .cancelled, "esc cancels")
        check(Hotkeys.capture(isKeyDown: true, keyCode: 12, flags: 0) == .none, "letter ignored")
        check(Hotkeys.capture(isKeyDown: false, keyCode: 62, flags: 0x40000) == .captured(Hotkeys.key(named: "rightctrl")!), "right ctrl press captured")
        check(Hotkeys.capture(isKeyDown: false, keyCode: 62, flags: 0) == .none, "release ignored")
        check(Hotkeys.capture(isKeyDown: false, keyCode: 57, flags: 0x10000) == .none, "caps lock not a hotkey")
        return ok
    }
}
