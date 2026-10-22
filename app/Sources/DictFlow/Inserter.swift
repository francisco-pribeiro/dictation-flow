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

    /// Snapshot, write, paste, then restore after 250 ms if nobody else touched the clipboard.
    func insert(_ text: String) {
        if IsSecureEventInputEnabled() || NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            _ = write(text)   // leave it on the clipboard for a manual paste
            NSSound.beep()
            return
        }
        let snap = snapshot()
        let count = write(text)
        pasteFunction()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            if pb.changeCount == count { restore(snap) }
        }
    }

    /// Headless round-trip check used by --clipboard-test.
    func selfTest() -> Bool {
        let original = snapshot()
        let probe = "dictflow-probe-\(UUID().uuidString)"
        let count = write(probe)
        let wrote = pb.string(forType: .string) == probe && pb.changeCount == count
        restore(original)
        let after = snapshot()
        let same = after.count == original.count && zip(after, original).allSatisfy { a, b in
            a.count == b.count && Dictionary(uniqueKeysWithValues: a.map { ($0.0, $0.1) }) == Dictionary(uniqueKeysWithValues: b.map { ($0.0, $0.1) })
        }
        return wrote && same
    }
}
