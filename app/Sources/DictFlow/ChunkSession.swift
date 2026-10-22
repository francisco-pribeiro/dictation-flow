import Foundation

/// One chunked dictation: PCM in, Segmenter closes segments, ChunkAssembler sends them, one result out.
/// Used by the app (behind DICTFLOW_CHUNKING) and by --chunk-sim, so the simulation exercises the real code.
final class ChunkSession {
    private let q = DispatchQueue(label: "dictflow.chunk")
    private var segmenter: Segmenter
    private let asm: ChunkAssembler
    private let secureCheck: () -> Bool
    private var secure = false
    private var cancelled = false

    /// `secureCheck` runs on the session queue each time a segment closes: once it reports a secure field,
    /// every later segment is sent with cleanup=0.
    init(config: Segmenter.Config, chain: Bool, secureCheck: @escaping () -> Bool, transport: @escaping ChunkAssembler.Transport) {
        segmenter = Segmenter(config: config)
        asm = ChunkAssembler(chain: chain, transport: transport)
        self.secureCheck = secureCheck
    }

    /// Any thread; PCM is raw Int16 LE. Order is preserved by the serial queue.
    func feed(_ pcm: Data) {
        q.async { [self] in
            guard !cancelled else { return }
            for s in segmenter.feed(pcm) {
                if !secure { secure = secureCheck() }
                asm.submit(wav: WavFormat.wav(fromPCM: s.pcm), cleanup: !secure)
            }
        }
    }

    struct Result {
        let outcome: ChunkAssembler.Outcome
        let tailAudio: Double    // seconds of audio in the last segment sent at release
    }

    /// Release. `secureAtRelease` is the main-thread check main also does. `done` runs on an arbitrary thread.
    func finish(secureAtRelease: Bool, done: @escaping (Result) -> Void) {
        q.async { [self] in
            guard !cancelled else { return }
            let tail = segmenter.finish()
            // Only silence left after the last cut: nothing to send. Nothing sent so far: send it anyway (main's path).
            let send = tail.hasSpeech || segmenter.emitted == 0
            let audio = send ? Double(tail.segment.pcm.count) / 32000 : 0
            asm.finish(tail: send ? (WavFormat.wav(fromPCM: tail.segment.pcm), !(secure || secureAtRelease)) : nil) { o in
                done(Result(outcome: o, tailAudio: audio))
            }
        }
    }

    func cancel() {
        q.async { [self] in cancelled = true; asm.cancel() }
    }
}

extension ChunkSession {
    /// End to end with a fake transport: audio with pauses in, one assembled text out, in order, with context chaining.
    static func selfTest() -> Bool {
        var ok = true
        func check(_ c: Bool, _ m: String) { if !c { ok = false; FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)) } }
        var seed: UInt32 = 99
        func tone(_ secs: Double, _ loud: Bool) -> Data {
            var d = Data()
            for i in 0..<Int(secs * 16000) {
                seed = seed &* 1664525 &+ 1013904223
                let n = (Double(seed >> 16) / 65535 - 0.5) * 0.004
                var s = Int16((loud ? 0.2 * sin(Double(i) * 0.0863) + n : n) * 32767).littleEndian
                withUnsafeBytes(of: &s) { d.append(contentsOf: $0) }
            }
            return d
        }
        let audio = tone(0.3, false) + tone(3, true) + tone(0.8, false) + tone(3, true) + tone(0.8, false) + tone(1, true) + tone(0.3, false)

        let lock = NSLock()
        var seen: [(Int, String?, Int)] = []   // seq, context, wav bytes
        let transport: ChunkAssembler.Transport = { req, done in
            lock.lock(); seen.append((req.seq, req.context, req.wav.count)); lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { done(.success(.init(text: "S\(req.seq).", meta: nil))) }
        }
        let s = ChunkSession(config: Segmenter.Config(), chain: true, secureCheck: { false }, transport: transport)
        var off = 0
        while off < audio.count { let e = min(off + 2720, audio.count); s.feed(audio.subdata(in: off..<e)); off = e }
        let sem = DispatchSemaphore(value: 0)
        var res: Result?
        s.finish(secureAtRelease: false) { res = $0; sem.signal() }
        check(sem.wait(timeout: .now() + 5) == .success, "session finishes")
        check(res?.outcome.text == "S0. S1. S2.", "three segments assembled in order: \(res?.outcome.text ?? "nil")")
        lock.lock()
        check(seen.map { $0.0 } == [0, 1, 2], "sent in order: \(seen.map { $0.0 })")
        check(seen.count == 3 && seen[0].1 == nil && seen[1].1 == "S0." && seen[2].1 == "S1.", "context chain: \(seen.map { $0.1 ?? "-" })")
        check(seen.reduce(0) { $0 + $1.2 - 44 } == audio.count, "segment audio sums to the whole recording")
        lock.unlock()

        // No pauses: the one request is the whole recording as main would send it.
        let cont = tone(0.3, false) + tone(4, true) + tone(0.3, false)
        seen = []
        let s2 = ChunkSession(config: Segmenter.Config(), chain: true, secureCheck: { false }, transport: transport)
        s2.feed(cont)
        let sem2 = DispatchSemaphore(value: 0)
        s2.finish(secureAtRelease: false) { _ in sem2.signal() }
        check(sem2.wait(timeout: .now() + 5) == .success, "single finishes")
        check(seen.count == 1 && seen[0].1 == nil && seen[0].2 == WavFormat.wav(fromPCM: cont).count, "no pauses: one request, whole recording, no context")

        // Secure field seen when a segment closes: that and later segments go without cleanup.
        var cleanups: [Bool] = []
        let t3: ChunkAssembler.Transport = { req, done in
            lock.lock(); cleanups.append(req.cleanup); lock.unlock()
            done(.success(.init(text: "x", meta: nil)))
        }
        let s3 = ChunkSession(config: Segmenter.Config(), chain: true, secureCheck: { true }, transport: t3)
        s3.feed(audio)
        let sem3 = DispatchSemaphore(value: 0)
        s3.finish(secureAtRelease: false) { _ in sem3.signal() }
        _ = sem3.wait(timeout: .now() + 5)
        check(!cleanups.isEmpty && cleanups.allSatisfy { !$0 }, "secure field: cleanup off for every segment")

        // Esc: nothing is delivered.
        var delivered = false
        let s4 = ChunkSession(config: Segmenter.Config(), chain: true, secureCheck: { false }, transport: transport)
        s4.feed(audio); s4.cancel()
        s4.finish(secureAtRelease: false) { _ in delivered = true }
        Thread.sleep(forTimeInterval: 0.3)
        check(!delivered, "Esc delivers nothing")
        return ok
    }
}
