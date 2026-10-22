import AppKit

/// Push-to-talk via a listen-only CGEventTap on its own run-loop thread. Callbacks fire on the main queue.
final class HotkeyMonitor {
    static let minHold: TimeInterval = 0.25
    static let maxHold: TimeInterval = 120

    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}

    var onCaptured: (HotkeyKey) -> Void = { _ in }
    var onCaptureCancelled: () -> Void = {}

    private let lock = NSLock()
    private var key: HotkeyKey
    private var capturing = false
    private var keyCode: Int64 { lock.lock(); defer { lock.unlock() }; return key.keyCode }
    private var mask: CGEventFlags { lock.lock(); defer { lock.unlock() }; return CGEventFlags(rawValue: key.flag) }
    // Touched only on the tap thread.
    private var keyIsDown = false
    private var holding = false
    private var downAt: Date?
    private var timer: CFRunLoopTimer?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var thread: Thread?

    init(key: HotkeyKey) { self.key = key }

    /// Takes effect immediately; any hold in progress is dropped on the tap thread's next event.
    func setKey(_ k: HotkeyKey) {
        lock.lock(); key = k; lock.unlock()
        keyIsDown = false
    }

    /// The next modifier-only press becomes the new key (reported via onCaptured); Esc cancels.
    func beginCapture() { lock.lock(); capturing = true; lock.unlock() }
    func endCapture() { lock.lock(); capturing = false; lock.unlock() }
    private var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return capturing }

    /// Returns false when the tap cannot be created (missing Input Monitoring permission).
    func start() -> Bool {
        if thread != nil { return true }
        let events: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: events, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        let th = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            let src = CFMachPortCreateRunLoopSource(nil, t, 0)
            CFRunLoopAddSource(runLoop, src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.name = "dictflow-hotkey"
        thread = th
        th.start()
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if isCapturing, type == .keyDown || type == .flagsChanged {
            switch Hotkeys.capture(isKeyDown: type == .keyDown, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags.rawValue) {
            case .captured(let k): endCapture(); DispatchQueue.main.async { self.onCaptured(k) }
            case .cancelled: endCapture(); DispatchQueue.main.async { self.onCaptureCancelled() }
            case .none: break
            }
            return
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Missed events: drop any hold in progress, then re-enable.
            if holding { finish(cancel: true) }
            keyIsDown = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if holding { finish(cancel: true) }   // chord, e.g. Option+2 = @
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == keyCode else { return }
            if !event.flags.contains(mask) {
                keyIsDown = false
                if holding { finish(cancel: heldFor() < Self.minHold) }
            } else if !keyIsDown {
                keyIsDown = true
                beginHold()
            } else {
                // Flag still set but our key toggled: another key with the same flag (e.g. left Option) is held.
                keyIsDown = false
                if holding { finish(cancel: heldFor() < Self.minHold) }
            }
        default: break
        }
    }

    private func heldFor() -> TimeInterval { downAt.map { Date().timeIntervalSince($0) } ?? 0 }

    private func beginHold() {
        holding = true
        downAt = Date()
        let t = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + Self.maxHold, 0, 0, 0) { [weak self] _ in
            guard let self, self.holding else { return }
            self.finish(cancel: false)   // auto stop at the cap
        }
        timer = t
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, .commonModes)
        DispatchQueue.main.async { self.onStart() }
    }

    private func finish(cancel: Bool) {
        holding = false
        if let timer { CFRunLoopTimerInvalidate(timer) }
        timer = nil
        DispatchQueue.main.async { cancel ? self.onCancel() : self.onStop() }
    }
}
