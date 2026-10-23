import AppKit
import ApplicationServices

/// Advisory check: is something focused that can take pasted text? Conservative on purpose;
/// anything uncertain (poor AX exposure in Chrome/Electron/terminals, errors, timeouts) counts as OK.
enum FocusProbe {
    enum Verdict { case canAccept, cannotAccept, unknown }

    /// Roles that clearly cannot take text, unless the element shows positive evidence of editing.
    static let noTextRoles: Set<String> = [
        "AXWindow", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXMenuBar", "AXMenu", "AXList", "AXTable", "AXOutline", "AXRow", "AXColumn",
        "AXImage", "AXSlider", "AXTabGroup", "AXToolbar", "AXDesktop",
    ]
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Containers that say nothing about editability. Only trusted as "no text" in native apps with good AX support.
    static let weakRoles: Set<String> = ["AXScrollArea", "AXGroup", "AXApplication", "AXStaticText", "AXSplitGroup", "AXLayoutArea"]
    static let nativeBundles: Set<String> = [
        "com.apple.finder", "com.apple.Notes", "com.apple.TextEdit", "com.apple.mail", "com.apple.systempreferences",
        "com.apple.Preview", "com.apple.reminders", "com.apple.iCal", "com.apple.AddressBook", "com.apple.Photos",
    ]

    /// Pure decision from what the focused element exposes.
    static func decide(role: String?, valueSettable: Bool, hasSelectedTextRange: Bool, nativeApp: Bool = false) -> Verdict {
        if let role, textRoles.contains(role) { return .canAccept }
        if valueSettable || hasSelectedTextRange { return .canAccept }
        if let role, noTextRoles.contains(role) { return .cannotAccept }
        if nativeApp, let role, weakRoles.contains(role) { return .cannotAccept }
        return .unknown   // AXWebArea, weak roles in non-native apps, missing role...
    }

    private static let logQueue = DispatchQueue(label: "dictflow.focuslog", qos: .utility)
    private static let logPath = NSHomeDirectory() + "/Library/Logs/DictFlow/focus.log"
    private static let logMax = 200_000

    private static func attr(_ el: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var v: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return (e, v)
    }

    private static func appendLog(_ line: String) {
        logQueue.async {
            let fm = FileManager.default
            let dir = (logPath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !fm.fileExists(atPath: logPath) { fm.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600]) }
            guard let h = FileHandle(forWritingAtPath: logPath) else { return }
            defer { try? h.close() }
            guard let size = try? h.seekToEnd(), (try? h.write(contentsOf: Data(line.utf8))) != nil else { return }
            if size > UInt64(logMax), let data = fm.contents(atPath: logPath), data.count > 2 {
                var tail = data.suffix(from: data.startIndex + data.count / 2)
                if let nl = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: nl + 1) }
                try? Data(tail).write(to: URL(fileURLWithPath: logPath), options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPath)
            }
        }
    }

    /// True only when there is clearly nowhere to paste. Safe to call off the main thread.
    /// Appends one diagnostic line (no transcript text) to ~/Library/Logs/DictFlow/focus.log.
    static func clearlyNoTarget(pid: pid_t?) -> Bool {
        let trusted = AXIsProcessTrusted()
        let bundle = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } ?? "?"
        let native = nativeBundles.contains(bundle)
        var d: [String] = ["trusted=\(trusted)", "app=\(bundle)", "native=\(native)"]
        var verdict = false
        defer {
            d.append("alert=\(verdict)")
            var t = time_t(Date().timeIntervalSince1970); var tmv = tm(); gmtime_r(&t, &tmv)
            let ts = String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday, tmv.tm_hour, tmv.tm_min, tmv.tm_sec)
            appendLog(ts + " " + d.joined(separator: " ") + "\n")
        }

        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.1)
        var (err, ref) = attr(sys, kAXFocusedUIElementAttribute as String)
        d.append("sys_err=\(err.rawValue)")

        let app: AXUIElement? = pid.map { AXUIElementCreateApplication($0) }
        if let app { AXUIElementSetMessagingTimeout(app, 0.1) }
        var appErr: AXError?
        // The system-wide query is flaky (cannotComplete, or answers for another app); fall back to the frontmost app's own.
        if !(err == .success && ref != nil), let app {
            let r = attr(app, kAXFocusedUIElementAttribute as String)
            appErr = r.0
            d.append("app_focus_err=\(r.0.rawValue)")
            if r.0 == .success { err = .success; ref = r.1 }
        }

        if err == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let el = ref as! AXUIElement
            AXUIElementSetMessagingTimeout(el, 0.1)
            let (roleErr, role) = attr(el, kAXRoleAttribute as String)
            let (subErr, sub) = attr(el, kAXSubroleAttribute as String)
            var settable: DarwinBoolean = false
            let setErr = AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
            let (selErr, _) = attr(el, kAXSelectedTextRangeAttribute as String)
            let v = decide(role: role as? String, valueSettable: settable.boolValue,
                           hasSelectedTextRange: selErr == .success, nativeApp: native)
            verdict = v == .cannotAccept
            d.append("role=\(role as? String ?? "nil")(\(roleErr.rawValue)) subrole=\(sub as? String ?? "nil")(\(subErr.rawValue)) "
                     + "valueSettable=\(settable.boolValue)(\(setErr.rawValue)) selRange=\(selErr == .success)(\(selErr.rawValue)) verdict=\(v)")
            return verdict
        }

        // No focused element anywhere. Alarm when the frontmost app also has no focused window (desktop, empty Finder).
        guard let app, err == .noValue || appErr == .noValue else { d.append("verdict=unknown(no element, error)"); return false }
        let (winErr, _) = attr(app, kAXFocusedWindowAttribute as String)
        d.append("win_err=\(winErr.rawValue)")
        verdict = winErr == .noValue
        d.append("verdict=noFocusedElement")
        return verdict
    }

    static func selfTest() -> Bool {
        decide(role: "AXTextField", valueSettable: false, hasSelectedTextRange: false) == .canAccept
            && decide(role: "AXTextArea", valueSettable: false, hasSelectedTextRange: false) == .canAccept
            && decide(role: "AXGroup", valueSettable: true, hasSelectedTextRange: false) == .canAccept
            && decide(role: "AXStaticText", valueSettable: false, hasSelectedTextRange: true) == .canAccept
            && decide(role: "AXButton", valueSettable: false, hasSelectedTextRange: false) == .cannotAccept
            && decide(role: "AXWindow", valueSettable: false, hasSelectedTextRange: false) == .cannotAccept
            && decide(role: "AXList", valueSettable: false, hasSelectedTextRange: false) == .cannotAccept
            && decide(role: "AXWebArea", valueSettable: false, hasSelectedTextRange: false) == .unknown
            && decide(role: "AXGroup", valueSettable: false, hasSelectedTextRange: false) == .unknown
            && decide(role: nil, valueSettable: false, hasSelectedTextRange: false) == .unknown
            && decide(role: "AXScrollArea", valueSettable: false, hasSelectedTextRange: false, nativeApp: true) == .cannotAccept
            && decide(role: "AXScrollArea", valueSettable: false, hasSelectedTextRange: false, nativeApp: false) == .unknown
            && decide(role: "AXScrollArea", valueSettable: false, hasSelectedTextRange: true, nativeApp: true) == .canAccept
    }
}
