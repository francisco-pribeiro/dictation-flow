import Foundation

/// Pure push-to-talk state machine: hold-to-talk plus hands-free (double-tap latches the recording).
/// No I/O and no clock of its own: every event carries its timestamp, so the logic is unit-testable.
/// Single-threaded: HotkeyMonitor drives it on the main queue.
struct HotkeyMachine {
    enum Action: Equatable { case start, stop, cancel, latch }
    enum Mode: Equatable { case idle, holding, latched }

    static let minHold: TimeInterval = 0.25         // a press shorter than this is a tap
    static let doubleTapWindow: TimeInterval = 0.4  // second press within this of the first release
    static let maxHold: TimeInterval = 120

    private(set) var mode = Mode.idle
    private var pressedAt = Date.distantPast
    private var startedAt = Date.distantPast
    private var secondPress = false
    private var lastTapRelease: Date?
    private var ignoreRelease = false   // the release that belongs to a press we already handled

    var isActive: Bool { mode != .idle }

    /// `busy`: the app is transcribing (or otherwise cannot record); the press and its release are ignored.
    mutating func press(at t: Date, busy: Bool) -> [Action] {
        switch mode {
        case .latched:
            mode = .idle; ignoreRelease = true; lastTapRelease = nil
            return [.stop]
        case .holding:
            return []
        case .idle:
            if busy { ignoreRelease = true; lastTapRelease = nil; return [] }
            secondPress = lastTapRelease.map { t.timeIntervalSince($0) <= Self.doubleTapWindow } ?? false
            lastTapRelease = nil
            ignoreRelease = false
            mode = .holding; pressedAt = t; startedAt = t
            return [.start]
        }
    }

    mutating func release(at t: Date) -> [Action] {
        if ignoreRelease { ignoreRelease = false; return [] }
        guard mode == .holding else { return [] }
        let short = t.timeIntervalSince(pressedAt) < Self.minHold
        if short && secondPress { mode = .latched; return [.latch] }   // recording keeps going
        mode = .idle
        if short { lastTapRelease = t; return [.cancel] }              // a lone tap records nothing
        lastTapRelease = nil
        return [.stop]
    }

    /// Any other key went down. Cancels a hold (chord such as Option+2); ignored while latched.
    mutating func chord() -> [Action] {
        guard mode == .holding else { return [] }
        mode = .idle; ignoreRelease = true; lastTapRelease = nil
        return [.cancel]
    }

    /// Esc cancels a latched recording without pasting; during a hold it acts like any other key.
    mutating func esc() -> [Action] {
        guard mode == .latched else { return chord() }
        mode = .idle; lastTapRelease = nil
        return [.cancel]
    }

    /// Call at least `maxHold` after a start; stops a recording that ran to the cap.
    mutating func tick(at t: Date) -> [Action] {
        guard isActive, t.timeIntervalSince(startedAt) >= Self.maxHold else { return [] }
        if mode == .holding { ignoreRelease = true }
        mode = .idle; lastTapRelease = nil
        return [.stop]
    }

    /// The tap was disabled or the key changed: key state is unknown, drop everything.
    mutating func reset() -> [Action] {
        let was = isActive
        mode = .idle; ignoreRelease = false; lastTapRelease = nil
        return was ? [.cancel] : []
    }

    /// `.start` could not begin recording (e.g. no microphone permission).
    mutating func startFailed() {
        mode = .idle; ignoreRelease = true; lastTapRelease = nil
    }

    static func selfTest() -> Bool {
        var ok = true
        func check(_ c: Bool, _ m: String) { if !c { ok = false; print("FAIL: \(m)") } }
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

        // hold
        var m = HotkeyMachine()
        check(m.press(at: at(0), busy: false) == [.start], "hold: press starts")
        check(m.release(at: at(1.5)) == [.stop], "hold: release stops")
        check(m.mode == .idle, "hold: idle after")

        // tap: cancelled, nothing latched
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false)
        check(m.release(at: at(0.1)) == [.cancel], "tap: cancelled")
        check(m.mode == .idle, "tap: idle")
        // a second press after the window is a fresh first press
        check(m.press(at: at(0.1 + 0.5), busy: false) == [.start], "tap, late press starts")
        check(m.release(at: at(0.1 + 0.6)) == [.cancel], "tap after window is a lone tap, not a latch")

        // double-tap latches, next press stops, its release is ignored
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false); _ = m.release(at: at(0.1))
        check(m.press(at: at(0.3), busy: false) == [.start], "double: second press starts")
        check(m.release(at: at(0.4)) == [.latch], "double: second short release latches")
        check(m.mode == .latched, "double: latched")
        check(m.press(at: at(10), busy: false) == [.stop], "latched: next press stops")
        check(m.release(at: at(10.1)) == [], "latched: stop press release ignored")
        check(m.mode == .idle, "latched: idle after stop")

        // second press at exactly the edge of the window, and just past it
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false); _ = m.release(at: at(0.1))
        _ = m.press(at: at(0.1 + 0.4), busy: false)
        check(m.release(at: at(0.1 + 0.45)) == [.latch], "double: 400 ms after release still counts")
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false); _ = m.release(at: at(0.1))
        _ = m.press(at: at(0.1 + 0.41), busy: false)
        check(m.release(at: at(0.1 + 0.46)) == [.cancel], "double: 410 ms after release does not count")

        // second press held long is a normal hold (key released late)
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false); _ = m.release(at: at(0.1))
        _ = m.press(at: at(0.2), busy: false)
        check(m.release(at: at(2.0)) == [.stop], "late release of 2nd press: normal hold, stops")
        check(m.mode == .idle, "late release: idle")

        // first press held long: normal hold, and it does not arm a double-tap
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false)
        check(m.release(at: at(0.8)) == [.stop], "long first press stops")
        _ = m.press(at: at(0.9), busy: false)
        check(m.release(at: at(1.0)) == [.cancel], "tap right after a long hold is a lone tap")

        // triple-tap: tap, tap latches, third press stops; a fourth quick press does not re-latch
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false); _ = m.release(at: at(0.1))
        _ = m.press(at: at(0.2), busy: false); _ = m.release(at: at(0.3))
        check(m.mode == .latched, "triple: latched after two")
        check(m.press(at: at(0.4), busy: false) == [.stop], "triple: third press stops")
        check(m.release(at: at(0.5)) == [], "triple: third release ignored")
        check(m.press(at: at(0.6), busy: true) == [], "triple: fourth press while transcribing ignored")
        check(m.release(at: at(0.7)) == [], "triple: fourth release ignored")
        check(m.mode == .idle, "triple: idle")

        // tap during transcription: ignored, and does not count towards a double-tap
        m = HotkeyMachine()
        check(m.press(at: at(0), busy: true) == [], "busy press ignored")
        check(m.release(at: at(0.1)) == [], "busy release ignored")
        check(m.press(at: at(0.2), busy: false) == [.start], "press after busy tap is a first press")
        check(m.release(at: at(0.3)) == [.cancel], "busy tap did not arm a latch")

        // Esc while latched cancels; Esc when idle does nothing; Esc during a hold cancels like a chord
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false); _ = m.release(at: at(0.1))
        _ = m.press(at: at(0.2), busy: false); _ = m.release(at: at(0.3))
        check(m.esc() == [.cancel], "esc cancels latched")
        check(m.mode == .idle, "esc: idle")
        check(m.press(at: at(0.4), busy: false) == [.start], "after esc a press starts fresh")
        check(m.release(at: at(0.45)) == [.cancel], "after esc, no leftover latch window")
        check(m.esc() == [], "esc idle ignored")
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false)
        check(m.esc() == [.cancel], "esc during hold cancels")
        check(m.release(at: at(1)) == [], "release after cancelled hold ignored")

        // chord during a hold cancels; chord while latched is ignored
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false)
        check(m.chord() == [.cancel], "chord cancels hold")
        check(m.release(at: at(0.1)) == [], "chord: release ignored")
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false); _ = m.release(at: at(0.1))
        _ = m.press(at: at(0.2), busy: false); _ = m.release(at: at(0.3))
        check(m.chord() == [] && m.mode == .latched, "typing while latched does not cancel")

        // chord on the first tap prevents a later latch
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false); _ = m.chord(); _ = m.release(at: at(0.1))
        _ = m.press(at: at(0.2), busy: false)
        check(m.release(at: at(0.3)) == [.cancel], "chorded tap does not arm a double-tap")

        // max hold cap, for a hold and for a latch
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false)
        check(m.tick(at: at(60)) == [], "tick before cap does nothing")
        check(m.tick(at: at(120)) == [.stop], "tick at cap stops hold")
        check(m.release(at: at(125)) == [], "release after cap ignored")
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false); _ = m.release(at: at(0.1))
        _ = m.press(at: at(0.2), busy: false); _ = m.release(at: at(0.3))
        check(m.tick(at: at(121)) == [.stop] && m.mode == .idle, "tick at cap stops latch")
        check(m.tick(at: at(200)) == [], "tick when idle does nothing")

        // reset and failed start
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false)
        check(m.reset() == [.cancel] && m.mode == .idle, "reset cancels active")
        check(m.reset() == [], "reset idle is a no-op")
        m = HotkeyMachine()
        _ = m.press(at: at(0), busy: false); m.startFailed()
        check(m.release(at: at(0.1)) == [] && m.mode == .idle, "failed start: release ignored")
        return ok
    }
}
