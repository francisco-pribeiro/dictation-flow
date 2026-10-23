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

    /// Pure decision from what the focused element exposes.
    static func decide(role: String?, valueSettable: Bool, hasSelectedTextRange: Bool) -> Verdict {
        if let role, textRoles.contains(role) { return .canAccept }
        if valueSettable || hasSelectedTextRange { return .canAccept }
        if let role, noTextRoles.contains(role) { return .cannotAccept }
        return .unknown   // AXWebArea, AXGroup, AXScrollArea, AXApplication, missing role...
    }

    /// True only when there is clearly nowhere to paste. Safe to call off the main thread.
    static func clearlyNoTarget(pid: pid_t?) -> Bool {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.1)
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref)
        if err == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let el = ref as! AXUIElement
            AXUIElementSetMessagingTimeout(el, 0.1)
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            var settable: DarwinBoolean = false
            _ = AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
            var sel: CFTypeRef?
            let selErr = AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &sel)
            return decide(role: role as? String, valueSettable: settable.boolValue,
                          hasSelectedTextRange: selErr == .success) == .cannotAccept
        }
        // Only a definite "nothing focused" is actionable; errors/timeouts/API-disabled stay quiet.
        guard err == .noValue, let pid else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var r2: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &r2) == .noValue else { return false }
        // The app has no focused element either; alarm only when it also has no focused window (desktop, empty Finder).
        var win: CFTypeRef?
        return AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .noValue
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
    }
}
