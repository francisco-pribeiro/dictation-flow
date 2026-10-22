import AppKit

/// Push-to-talk via a listen-only CGEventTap on its own run-loop thread. Raw key events are forwarded to the
/// main queue, where `HotkeyMachine` decides (hold, tap, double-tap latch). Callbacks fire on the main queue.
final class HotkeyMonitor {
    var onStart: () -> Bool = { true }   // false = recording could not begin
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
    var onLatch: () -> Void = {}
    var isBusy: () -> Bool = { false }   // app is transcribing: presses are ignored

    var onCaptured: (HotkeyKey) -> Void = { _ in }
    var onCaptureCancelled: () -> Void = {}

    private let lock = NSLock()
    private var key: HotkeyKey
    private var capturing = false
    private var keyCode: Int64 { lock.lock(); defer { lock.unlock() }; return key.keyCode }
    private var mask: CGEventFlags { lock.lock(); defer { lock.unlock() }; return CGEventFlags(rawValue: key.flag) }
    // Touched only on the tap thread.
    private var keyIsDown = false
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var thread: Thread?
    // Touched only on the main queue.
    private var machine = HotkeyMachine()

    init(key: HotkeyKey) { self.key = key }

    /// Takes effect immediately; any recording in progress is dropped on the main queue.
    func setKey(_ k: HotkeyKey) {
        lock.lock(); key = k; lock.unlock()
        keyIsDown = false
        DispatchQueue.main.async { self.apply(self.machine.reset()) }
    }

    /// Drops a hold in progress (another shortcut took the keys). A latched recording is unaffected. Main queue.
    func cancelHold() { apply(machine.chord()) }

    /// The next clean modifier-only tap becomes the new key (reported via onCaptured); Esc cancels.
    func beginCapture() { lock.lock(); capturing = true; capturer = HotkeyCapturer(); lock.unlock() }
    func endCapture() { lock.lock(); capturing = false; lock.unlock() }
    private var capturer = HotkeyCapturer()   // guarded by lock
    private func feedCapture(isKeyDown: Bool, keyCode: Int64, flags: UInt64) -> Hotkeys.CaptureResult {
        lock.lock(); defer { lock.unlock() }
        return capturer.feed(isKeyDown: isKeyDown, keyCode: keyCode, flags: flags)
    }
    private func breakCapture() { lock.lock(); capturer.interrupt(); lock.unlock() }
    private var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return capturing }

    /// Returns false when the tap cannot be created (missing Input Monitoring permission).
    func start() -> Bool {
        if thread != nil { return true }
        let events: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
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
        if isCapturing, type == .keyDown || type == .flagsChanged || type.isMouseDown {
            if type.isMouseDown { breakCapture(); return }
            switch feedCapture(isKeyDown: type == .keyDown, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags.rawValue) {
            case .captured(let k): endCapture(); DispatchQueue.main.async { self.onCaptured(k) }
            case .cancelled: endCapture(); DispatchQueue.main.async { self.onCaptureCancelled() }
            case .none: break
            }
            return
        }
        let now = Date()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Missed events: drop any recording in progress, then re-enable.
            keyIsDown = false
            DispatchQueue.main.async { self.apply(self.machine.reset()) }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Modifier+click is not a dictation hold.
            DispatchQueue.main.async { self.apply(self.machine.chord()) }
        case .keyDown:
            let isEsc = event.getIntegerValueField(.keyboardEventKeycode) == Hotkeys.escKeyCode
            DispatchQueue.main.async { self.apply(isEsc ? self.machine.esc() : self.machine.chord()) }
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == keyCode else { return }
            if !event.flags.contains(mask) {
                guard keyIsDown else { return }
                keyIsDown = false
                DispatchQueue.main.async { self.apply(self.machine.release(at: now)) }
            } else if !keyIsDown {
                keyIsDown = true
                DispatchQueue.main.async { self.apply(self.machine.press(at: now, busy: self.isBusy())) }
            } else {
                // Flag still set but our key toggled: another key with the same flag (e.g. left Option) is held.
                keyIsDown = false
                DispatchQueue.main.async { self.apply(self.machine.release(at: now)) }
            }
        default: break
        }
    }

    private func apply(_ actions: [HotkeyMachine.Action]) {
        for a in actions {
            switch a {
            case .start:
                if onStart() {
                    // Safety cap: stop a recording that outlives maxHold (hold or latched).
                    DispatchQueue.main.asyncAfter(deadline: .now() + HotkeyMachine.maxHold + 0.05) { [weak self] in
                        guard let self else { return }
                        self.apply(self.machine.tick(at: Date()))
                    }
                } else { machine.startFailed() }
            case .stop: onStop()
            case .cancel: onCancel()
            case .latch: onLatch()
            }
        }
    }
}

private extension CGEventType {
    var isMouseDown: Bool { self == .leftMouseDown || self == .rightMouseDown || self == .otherMouseDown }
}
