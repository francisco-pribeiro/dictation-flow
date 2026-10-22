import AppKit
import Carbon.HIToolbox

/// Clipboard-based text insertion; Cmd-V is injected via `pasteFunction`.
final class Inserter {
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    var pasteFunction: () -> Void = {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
    private let pb = NSPasteboard.general

    func snapshot() -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
    }

    func restore(_ snap: Snapshot) {
        pb.clearContents()
        let items = snap.map { entries -> NSPasteboardItem in
            let it = NSPasteboardItem()
            for (t, d) in entries { it.setData(d, forType: t) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Put text on the clipboard flagged as transient/concealed; returns the changeCount after writing.
    func write(_ text: String) -> Int {
        pb.clearContents()
        pb.declareTypes([.string, Inserter.transient, Inserter.concealed], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: Inserter.transient)
        pb.setData(Data(), forType: Inserter.concealed)
        return pb.changeCount
    }

    /// True when the frontmost app is the one holding secure input (a password field). Secure input
    /// held by a background app is ignored.
    static func secureInputOnFrontmost() -> Bool {
        guard IsSecureEventInputEnabled(),
              let pid = (CGSessionCopyCurrentDictionary() as? [String: Any])?["kCGSSessionSecureInputPID"] as? Int32
        else { return false }
        return pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Called with a short reason when the text was left on the clipboard instead of pasted.
    var onFallback: (String) -> Void = { _ in }

    /// The clipboard as it was before the first still-pending insert, so a second insert within 1 s
    /// does not mistake our own transcript for the user's clipboard.
    private var pending: (snap: Snapshot, count: Int)?

    /// Writes the text, keeping the first snapshot while an earlier insert's restore is still pending.
    func stage(_ text: String) -> (snap: Snapshot, count: Int) {
        let snap = pending?.snap ?? snapshot()
        let count = write(text)
        pending = (snap, count)
        return (snap, count)
    }

    /// Snapshot, write, paste, then restore after 1 s if nobody else touched the clipboard.
    func insert(_ text: String) {
        let reason: String?
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { reason = "DictFlow is frontmost" }
        else if Inserter.secureInputOnFrontmost() { reason = "Secure input field" }
        else if !AXIsProcessTrusted() { reason = "Accessibility missing" }
        else { reason = nil }
        if let reason {
            _ = write(text)   // leave it on the clipboard for a manual paste
            onFallback("\(reason): text left on clipboard")
            NSSound.beep()
            return
        }
        let (snap, count) = stage(text)
        pasteFunction()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            guard pending?.count == count else { return }   // a newer insert owns the restore
            pending = nil
            if pb.changeCount == count { restore(snap) }
        }
    }

    private func sameItems(_ x: Snapshot, _ y: Snapshot) -> Bool {
        x.count == y.count && zip(x, y).allSatisfy { a, b in
            a.count == b.count && Dictionary(uniqueKeysWithValues: a.map { ($0.0, $0.1) }) == Dictionary(uniqueKeysWithValues: b.map { ($0.0, $0.1) })
        }
    }

    /// Headless round-trip check used by --clipboard-test.
    func selfTest() -> Bool {
        let original = snapshot()
        let probe = "dictflow-probe-\(UUID().uuidString)"
        let count = write(probe)
        let wrote = pb.string(forType: .string) == probe && pb.changeCount == count
        restore(original)
        let same = sameItems(snapshot(), original)
        // two stages within the restore window must still bring the original back
        let (snap1, _) = stage("first")
        let (snap2, c2) = stage("second")
        let twice = pb.changeCount == c2 && sameItems(snap1, snap2) && sameItems(snap1, original)
        restore(snap2)
        pending = nil
        return wrote && same && twice
    }
}
