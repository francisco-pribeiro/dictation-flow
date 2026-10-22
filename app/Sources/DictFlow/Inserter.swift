import AppKit

/// Clipboard-based text insertion. The actual Cmd-V is injected via `pasteFunction` (T7).
final class Inserter {
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    var pasteFunction: () -> Void = {}
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
