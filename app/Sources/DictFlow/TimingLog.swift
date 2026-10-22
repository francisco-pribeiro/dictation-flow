import Foundation

/// One line per dictation in ~/Library/Logs/DictFlow/timings.log: numbers and flags only, never text or app names.
/// record() formats a short string and enqueues; all file I/O happens on a background utility queue.
enum TimingLog {
    static let maxBytes = 1_000_000
    private static let queue = DispatchQueue(label: "dictflow.timinglog", qos: .utility)
    private static var path = NSHomeDirectory() + "/Library/Logs/DictFlow/timings.log"   // only touched on `queue`

    static func record(audio: Double, chars: Int, meta: WorkerClient.Meta, sendMs: UInt64, requestMs: UInt64, pasteMs: UInt64, totalMs: UInt64) {
        let line = format(date: Date(), audio: audio, chars: chars, meta: meta, sendMs: sendMs, requestMs: requestMs, pasteMs: pasteMs, totalMs: totalMs)
        queue.async { append(line) }
    }

    static func format(date: Date, audio: Double, chars: Int, meta: WorkerClient.Meta, sendMs: UInt64, requestMs: UInt64, pasteMs: UInt64, totalMs: UInt64) -> String {
        // Hand-built UTC timestamp: ISO8601DateFormatter is slow to create and not needed here.
        var t = time_t(date.timeIntervalSince1970)
        var tmv = tm()
        gmtime_r(&t, &tmv)
        let ts = "\(tmv.tm_year + 1900)-\(pad(tmv.tm_mon + 1))-\(pad(tmv.tm_mday))T\(pad(tmv.tm_hour)):\(pad(tmv.tm_min)):\(pad(tmv.tm_sec))Z"
        let a = Int(audio * 10 + 0.5)
        return "\(ts) audio=\(a / 10).\(a % 10)s chars=\(chars) engine=\(meta.engine) cleanup=\(meta.provider) fell_back=\(meta.fellBack) "
            + "worker_decode=\(meta.decode)ms worker_asr=\(meta.asr)ms worker_cleanup=\(meta.cleanup)ms worker_total=\(meta.total)ms "
            + "release_to_send=\(sendMs)ms request=\(requestMs)ms paste=\(pasteMs)ms total=\(totalMs)ms\n"
    }

    private static func pad(_ v: Int32) -> String { v < 10 ? "0\(v)" : "\(v)" }

    /// Runs on `queue` only. Every error is swallowed.
    private static func append(_ line: String) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        defer { try? h.close() }
        do {
            let size = try h.seekToEnd()
            try h.write(contentsOf: Data(line.utf8))
            if size > UInt64(maxBytes) { trim() }
        } catch {}
    }

    /// Drops the oldest half, cutting at a line boundary.
    private static func trim() {
        guard let data = FileManager.default.contents(atPath: path), data.count > 2 else { return }
        var tail = data.suffix(from: data.startIndex + data.count / 2)
        if let nl = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: nl + 1) }
        try? Data(tail).write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    static func selfTest() -> Bool {
        var ok = true
        func check(_ c: Bool, _ m: String) { if !c { ok = false; FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)) } }
        var meta = WorkerClient.Meta(); meta.engine = "mlx"; meta.provider = "none"; meta.asr = 120
        let l = format(date: Date(timeIntervalSince1970: 0), audio: 3.04, chars: 42, meta: meta, sendMs: 5, requestMs: 900, pasteMs: 20, totalMs: 925)
        check(l.hasPrefix("1970-01-01T00:00:00Z audio=3.0s chars=42 engine=mlx cleanup=none fell_back=false "), "format: \(l)")
        check(l.hasSuffix("total=925ms\n") && l.contains("worker_asr=120ms"), "fields")

        // Real file behaviour in a temp dir (queue is drained with a barrier sync; test only).
        let dir = NSTemporaryDirectory() + "dictflow-tl-\(getpid())"
        queue.sync { path = dir + "/sub/timings.log" }
        for _ in 0..<3 { record(audio: 1, chars: 1, meta: meta, sendMs: 1, requestMs: 1, pasteMs: 1, totalMs: 3) }
        queue.sync {}
        let attrs = try? FileManager.default.attributesOfItem(atPath: dir + "/sub/timings.log")
        check((attrs?[.posixPermissions] as? Int) == 0o600, "mode 0600")
        check((try? String(contentsOfFile: dir + "/sub/timings.log", encoding: .utf8))?.split(separator: "\n").count == 3, "3 lines")

        // Cap: a >1 MB file gets its oldest half dropped on the next write.
        let big = String(repeating: "x\n", count: 600_000)
        try? big.write(toFile: dir + "/sub/timings.log", atomically: true, encoding: .utf8)
        record(audio: 1, chars: 1, meta: meta, sendMs: 1, requestMs: 1, pasteMs: 1, totalMs: 3)
        queue.sync {}
        let sz = (try? FileManager.default.attributesOfItem(atPath: dir + "/sub/timings.log")[.size] as? Int) ?? 0
        check(sz > 0 && sz < 700_000, "trimmed size \(sz)")
        queue.sync { path = "/nonexistent-root/x/timings.log" }
        record(audio: 1, chars: 1, meta: meta, sendMs: 1, requestMs: 1, pasteMs: 1, totalMs: 3)   // must not crash
        queue.sync {}
        try? FileManager.default.removeItem(atPath: dir)

        // Cost on the calling thread: format + enqueue only (I/O is on the utility queue, pointed at a dead path).
        let n = 20_000
        var worst: UInt64 = 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n {
            let s = DispatchTime.now().uptimeNanoseconds
            record(audio: 3.2, chars: 120, meta: meta, sendMs: 5, requestMs: 900, pasteMs: 20, totalMs: 925)
            worst = max(worst, DispatchTime.now().uptimeNanoseconds - s)
        }
        let per = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(n) / 1000
        queue.sync {}
        print(String(format: "record() on caller thread: avg %.2f us, worst %.1f us over %d calls", per, Double(worst) / 1000, n))
        return ok
    }
}
