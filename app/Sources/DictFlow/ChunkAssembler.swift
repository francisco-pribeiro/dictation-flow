import Foundation

/// Numbers segments, sends each to the worker (segment N with segment N-1's final text as read-only context),
/// and joins the results in order once every segment has resolved. Pure logic: the transport is injected, so
/// out-of-order replies, failures, a restarted worker and Esc are all unit-tested with a fake.
final class ChunkAssembler {
    struct Request: Equatable {
        let seq: Int
        let wav: Data
        let context: String?   // previous segment's final text, nil when absent
        let cleanup: Bool
        let recover: Bool      // second attempt: the transport must ensure the worker is running first
        var partial = false    // not the last segment: the speaker may have paused mid-sentence
        var session = ""       // random id of this dictation (debug capture groups the pieces by it); "" in tests
    }

    struct Reply {
        let text: String
        let meta: WorkerClient.Meta?
        var raw = ""           // engine output before cleanup, for --chunk-sim --out only
    }

    /// Errors that a second attempt cannot fix (a 4xx: the worker understood and refused).
    struct NoRetry: Error {}

    typealias Transport = (Request, @escaping (Result<Reply, Error>) -> Void) -> Void

    struct Outcome {
        let text: String            // joined in order, single spaces, trimmed
        let failed: [Int]           // seqs that never produced text (the app beeps; the rest is still pasted)
        let segments: Int
        let raws: [String]          // per segment (after any merge), same order as the text
        let lastMeta: WorkerClient.Meta?
        let lastSentNs: UInt64      // when the final segment was issued
        let lastDoneNs: UInt64      // when it resolved
    }

    private enum State { case waiting, inFlight, done(String), failed }
    private struct Item {
        var wav: Data
        var cleanup: Bool
        var partial: Bool
        var raw = ""
        var state = State.waiting
        var attempt = 0
        var sentNs: UInt64 = 0
        var doneNs: UInt64 = 0
        var meta: WorkerClient.Meta?
    }

    static let contextChars = 600
    static let defaultDeadline: TimeInterval = 15   // release until delivery at the latest, like main's single request

    /// Segment WAVs (44-byte header each) joined into one WAV.
    static func joinWavs(_ wavs: [Data]) -> Data {
        var pcm = Data()
        for w in wavs { pcm.append(w.count > 44 ? w.subdata(in: 44..<w.count) : w) }
        return WavFormat.wav(fromPCM: pcm)
    }

    /// Only a refused connection or a dropped one (what a restarted worker produces) is worth a second attempt.
    /// A timeout is not: the worker is hung, and trying again only multiplies the wait.
    static func isConnectionError(_ e: Error) -> Bool {
        guard let u = e as? URLError else { return false }
        return u.code == .cannotConnectToHost || u.code == .networkConnectionLost
    }

    /// Joins segment texts. When the next piece starts in lower case and the previous one ended with a full stop,
    /// the cut fell inside a sentence (a pause to think), so the stop that cleanup added is dropped.
    static func joinTexts(_ texts: [String]) -> String {
        var out = ""
        for t in texts {
            if out.isEmpty { out = t; continue }
            if out.hasSuffix("."), !out.hasSuffix(".."), let f = t.first, f.isLowercase { out.removeLast() }
            out += " " + t
        }
        return out
    }

    private let transport: Transport
    private let chain: Bool
    private let now: () -> UInt64
    private let deadline: TimeInterval
    private let session: String
    private let join: ([Data]) -> Data
    private var degraded = false   // a segment has failed: the rest go out as one request
    private let lock = NSLock()
    private var items: [Item] = []
    private var generation = 0
    private var closed = false
    private var onFinished: ((Outcome) -> Void)?

    /// `chain`: segment N waits for N-1 and carries its text as context. Off: all segments go out at once, no context.
    init(chain: Bool = true, deadline: TimeInterval = ChunkAssembler.defaultDeadline, session: String = "",
         join: @escaping ([Data]) -> Data = ChunkAssembler.joinWavs,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }, transport: @escaping Transport) {
        self.chain = chain
        self.deadline = deadline
        self.session = session
        self.join = join
        self.now = now
        self.transport = transport
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }

    /// A segment closed while the speaker is still talking.
    func submit(wav: Data, cleanup: Bool) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        items.append(Item(wav: wav, cleanup: cleanup, partial: true))
        let out = pump()
        lock.unlock()
        run(out)
    }

    /// Release: optionally one last segment, then call `onFinished` (once) when everything has resolved.
    func finish(tail: (wav: Data, cleanup: Bool)?, onFinished: @escaping (Outcome) -> Void) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        if let tail { items.append(Item(wav: tail.wav, cleanup: tail.cleanup, partial: false)) }
        self.onFinished = onFinished
        let out = pump()
        let done = takeFinish()
        let gen = generation
        lock.unlock()
        run(out)
        if done == nil { DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { [self] in expire(gen) } }
        done?()
    }

    /// Overall deadline since release: deliver whatever has resolved, flag the rest as failed.
    private func expire(_ gen: Int) {
        lock.lock()
        guard gen == generation, onFinished != nil else { lock.unlock(); return }
        for i in items.indices where !resolved(items[i].state) {
            items[i].state = .failed
            items[i].doneNs = now()
            items[i].wav = Data()
        }
        let done = takeFinish()
        lock.unlock()
        done?()
    }

    /// Esc: forget everything in flight; late replies are ignored and nothing is delivered.
    func cancel() {
        lock.lock()
        generation += 1
        closed = true
        items = []
        onFinished = nil
        lock.unlock()
    }

    // MARK: internals (lock held unless noted)

    /// Marks issuable segments in flight and returns the requests to send (outside the lock).
    private func pump() -> [(Request, Int)] {
        var out: [(Request, Int)] = []
        var i = 0
        while i < items.count {
            defer { i += 1 }
            guard case .waiting = items[i].state else { continue }
            if chain, i > 0 { guard resolved(items[i - 1].state) else { break } }
            if degraded { mergeWaiting(from: i) }
            items[i].state = .inFlight
            items[i].sentNs = now()
            out.append((request(i, recover: false), generation))
        }
        return out
    }

    /// After a failure the worker is suspect: the audio of every segment not yet sent goes out as one request.
    private func mergeWaiting(from i: Int) {
        var j = i
        while j + 1 < items.count, case .waiting = items[j + 1].state { j += 1 }
        guard j > i else { return }
        items[i].wav = join(items[i...j].map(\.wav))
        items[i].cleanup = items[i...j].allSatisfy(\.cleanup)
        items[i].partial = items[j].partial
        items.removeSubrange((i + 1)...j)
    }

    private func resolved(_ s: State) -> Bool {
        switch s { case .done, .failed: return true; default: return false }
    }

    private func request(_ i: Int, recover: Bool) -> Request {
        var ctx: String?
        if chain, i > 0, items[i].cleanup, case .done(let t) = items[i - 1].state { ctx = ChunkAssembler.context(from: t) }
        return Request(seq: i, wav: items[i].wav, context: ctx, cleanup: items[i].cleanup, recover: recover,
                       partial: items[i].partial, session: session)
    }

    /// Last `contextChars` characters, starting at a word boundary; nil when empty.
    static func context(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.count <= contextChars { return t }
        var s = String(t.suffix(contextChars))
        if let sp = s.firstIndex(of: " ") { s = String(s[s.index(after: sp)...]) }
        return s
    }

    private func run(_ reqs: [(Request, Int)]) {
        for (r, gen) in reqs {
            transport(r) { [self] result in self.complete(seq: r.seq, gen: gen, result: result) }
        }
    }

    private func complete(seq: Int, gen: Int, result: Result<Reply, Error>) {
        lock.lock()
        guard gen == generation, seq < items.count, case .inFlight = items[seq].state else { lock.unlock(); return }
        var retry: (Request, Int)?
        switch result {
        case .success(let r):
            items[seq].state = .done(r.text.trimmingCharacters(in: .whitespacesAndNewlines))
            items[seq].meta = r.meta
            items[seq].raw = r.raw
            items[seq].doneNs = now()
            items[seq].wav = Data()
        case .failure(let e):
            if items[seq].attempt == 0, !(e is NoRetry), ChunkAssembler.isConnectionError(e) {
                items[seq].attempt = 1
                retry = (request(seq, recover: true), generation)
            } else {
                items[seq].state = .failed
                items[seq].doneNs = now()
                items[seq].wav = Data()
                degraded = true
            }
        }
        let out = retry == nil ? pump() : []
        let done = takeFinish()
        lock.unlock()
        if let retry { run([retry]) }
        run(out)
        done?()
    }

    /// If release happened and everything resolved, returns the one-shot delivery closure.
    private func takeFinish() -> (() -> Void)? {
        guard closed, let cb = onFinished, items.allSatisfy({ resolved($0.state) }) else { return nil }
        onFinished = nil
        var texts: [String] = [], failed: [Int] = []
        for (i, it) in items.enumerated() {
            switch it.state {
            case .done(let t): if !t.isEmpty { texts.append(t) }
            case .failed: failed.append(i)
            default: break
            }
        }
        let last = items.last
        let o = Outcome(text: ChunkAssembler.joinTexts(texts), failed: failed, segments: items.count, raws: items.map(\.raw),
                        lastMeta: last?.meta, lastSentNs: last?.sentNs ?? 0, lastDoneNs: last?.doneNs ?? 0)
        return { cb(o) }
    }

    // MARK: self test

    static func selfTest() -> Bool {
        var ok = true
        func check(_ c: Bool, _ m: String) { if !c { ok = false; FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)) } }

        /// Fake transport that records requests and lets the test choose when and how each one replies.
        final class Fake {
            var sent: [Request] = []
            var pending: [(Request, (Result<Reply, Error>) -> Void)] = []
            lazy var transport: Transport = { [self] r, cb in sent.append(r); pending.append((r, cb)) }
            func reply(_ seq: Int, _ text: String) {
                guard let i = pending.firstIndex(where: { $0.0.seq == seq }) else { return }
                let p = pending.remove(at: i); p.1(.success(Reply(text: text, meta: nil)))
            }
            func fail(_ seq: Int, _ e: Error = NSError(domain: "x", code: 1)) {
                guard let i = pending.firstIndex(where: { $0.0.seq == seq }) else { return }
                let p = pending.remove(at: i); p.1(.failure(e))
            }
        }
        func wav(_ n: UInt8) -> Data { Data([n]) }

        // 1. Single segment: exactly main's request (same body, no context, cleanup as asked).
        do {
            let f = Fake(); let a = ChunkAssembler(transport: f.transport); var out: Outcome?
            a.finish(tail: (wav(9), true)) { out = $0 }
            check(f.sent == [Request(seq: 0, wav: wav(9), context: nil, cleanup: true, recover: false)], "single segment request equals main's")
            f.reply(0, "  Olá mundo.  ")
            check(out?.text == "Olá mundo." && out?.failed == [] && out?.segments == 1, "single segment text")
        }
        // 2. Chain: N waits for N-1 and carries its final text; replies assemble in order; nothing delivered early.
        do {
            let f = Fake(); let a = ChunkAssembler(transport: f.transport); var out: Outcome?
            a.submit(wav: wav(1), cleanup: true); a.submit(wav: wav(2), cleanup: true)
            check(f.sent.count == 1 && f.sent[0].context == nil, "second segment waits for the first")
            f.reply(0, "Primeira.")
            check(f.sent.count == 2 && f.sent[1].context == "Primeira.", "context is the previous final text")
            a.finish(tail: (wav(3), true)) { out = $0 }
            check(f.sent.count == 2 && out == nil, "tail waits too, no early delivery")
            f.reply(1, "Segunda.")
            check(f.sent.count == 3 && f.sent[2].context == "Segunda.", "tail carries segment 1 text")
            f.reply(2, "Terceira.")
            check(out?.text == "Primeira. Segunda. Terceira.", "joined in order: \(out?.text ?? "nil")")
        }
        // 3. Out of order (no chaining): 3,1,2 still assemble as 1,2,3.
        do {
            let f = Fake(); let a = ChunkAssembler(chain: false, transport: f.transport); var out: Outcome?
            a.submit(wav: wav(1), cleanup: true); a.submit(wav: wav(2), cleanup: true)
            a.finish(tail: (wav(3), true)) { out = $0 }
            check(f.sent.count == 3 && f.sent.allSatisfy { $0.context == nil }, "unchained: all sent at once, no context")
            f.reply(2, "C."); f.reply(0, "A."); check(out == nil, "not delivered until all resolved")
            f.reply(1, "B.")
            check(out?.text == "A. B. C.", "out-of-order replies assemble in order: \(out?.text ?? "nil")")
        }
        // 4. A segment that fails twice: the others are still delivered, the failure is flagged, nothing dropped silently.
        do {
            let f = Fake(); let a = ChunkAssembler(transport: f.transport); var out: Outcome?
            a.submit(wav: wav(1), cleanup: true); a.submit(wav: wav(2), cleanup: true)
            a.finish(tail: (wav(3), true)) { out = $0 }
            f.reply(0, "Um.")
            f.fail(1, URLError(.cannotConnectToHost))
            check(f.sent.last?.seq == 1 && f.sent.last?.recover == true, "first failure retries once with recover")
            f.fail(1, URLError(.networkConnectionLost))
            check(f.sent.last?.seq == 2 && f.sent.last?.context == nil, "after a failed predecessor the next goes without context")
            f.reply(2, "Três.")
            check(out?.text == "Um. Três." && out?.failed == [1], "ready text pasted, failure flagged: \(out?.text ?? "nil") \(out?.failed ?? [])")
        }
        // 5. Worker restarted mid-dictation: connection refused, then OK on the single retry.
        do {
            let f = Fake(); let a = ChunkAssembler(transport: f.transport); var out: Outcome?
            a.finish(tail: (wav(1), true)) { out = $0 }
            f.fail(0, URLError(.cannotConnectToHost))
            check(f.sent.count == 2 && f.sent[1].recover && !f.sent[0].recover && f.sent[1].wav == wav(1), "retry resends the same audio with recover")
            f.reply(0, "Ok.")
            check(out?.text == "Ok." && out?.failed == [], "restart recovered")
        }
        // 6. NoRetry errors are not retried.
        do {
            let f = Fake(); let a = ChunkAssembler(transport: f.transport); var out: Outcome?
            a.finish(tail: (wav(1), true)) { out = $0 }
            f.fail(0, NoRetry())
            check(f.sent.count == 1 && out?.failed == [0] && out?.text == "", "NoRetry fails at once")
        }
        // 7. Esc with 2 segments in flight: nothing delivered, late replies ignored.
        do {
            let f = Fake(); let a = ChunkAssembler(chain: false, transport: f.transport); var out: Outcome?
            a.submit(wav: wav(1), cleanup: true); a.submit(wav: wav(2), cleanup: true)
            a.cancel()
            f.reply(0, "A."); f.reply(1, "B.")
            a.finish(tail: (wav(3), true)) { out = $0 }
            check(out == nil && f.sent.count == 2, "after Esc nothing is delivered or sent")
        }
        // 8. Empty segments (no speech) are skipped in the join; no segments at all finishes at once.
        do {
            let f = Fake(); let a = ChunkAssembler(transport: f.transport); var out: Outcome?
            a.submit(wav: wav(1), cleanup: true)
            a.finish(tail: (wav(2), true)) { out = $0 }
            f.reply(0, ""); f.reply(1, "Só esta.")
            check(out?.text == "Só esta." && out?.failed == [], "empty segment skipped")
            var empty: Outcome?
            ChunkAssembler(transport: f.transport).finish(tail: nil) { empty = $0 }
            check(empty?.text == "" && empty?.segments == 0, "no segments delivers immediately")
        }
        // 9. Secure input: a segment without cleanup carries no context; context is trimmed to a word boundary.
        do {
            let f = Fake(); let a = ChunkAssembler(transport: f.transport)
            a.submit(wav: wav(1), cleanup: true); a.submit(wav: wav(2), cleanup: false)
            f.reply(0, "Texto.")
            check(f.sent[1].cleanup == false && f.sent[1].context == nil, "no context sent for a cleanup=0 segment")
            let long = (0..<300).map { "palavra\($0)" }.joined(separator: " ")
            let c = ChunkAssembler.context(from: long)!
            check(c.count <= contextChars && c.hasSuffix("palavra299") && c.hasPrefix("palavra"), "context trimmed at a word boundary")
            check(ChunkAssembler.context(from: "  ") == nil, "blank context is nil")
        }
        // 10. A timeout (hung worker) is not retried; the rest of the audio then goes out as ONE request, kept in order.
        do {
            let f = Fake(); let a = ChunkAssembler(deadline: 5, join: { Data($0.joined()) }, transport: f.transport); var out: Outcome?
            a.submit(wav: wav(1), cleanup: true); a.submit(wav: wav(2), cleanup: true); a.submit(wav: wav(3), cleanup: true)
            a.finish(tail: (wav(4), true)) { out = $0 }
            f.fail(0, URLError(.timedOut))
            check(f.sent.count == 2, "timeout: no retry, rest merged into one request (sent \(f.sent.count))")
            check(f.sent.last?.seq == 1 && f.sent.last?.wav == Data([2, 3, 4]) && f.sent.last?.partial == false && f.sent.last?.context == nil,
                  "merged request carries all unresolved audio in order")
            f.reply(1, "Resto.")
            check(out?.text == "Resto." && out?.failed == [0] && out?.segments == 2, "merged result delivered: \(out?.text ?? "nil") \(out?.failed ?? [])")
        }
        // 11. Overall deadline from release: whatever resolved is delivered, the hung segments are flagged, late replies ignored.
        do {
            let f = Fake(); let a = ChunkAssembler(deadline: 0.15, transport: f.transport); var out: Outcome?
            let lk = NSLock()
            a.submit(wav: wav(1), cleanup: true); f.reply(0, "Feito.")
            a.submit(wav: wav(2), cleanup: true)
            a.finish(tail: (wav(3), true)) { lk.lock(); out = $0; lk.unlock() }
            Thread.sleep(forTimeInterval: 0.5)
            lk.lock(); let o = out; lk.unlock()
            check(o?.text == "Feito." && o?.failed == [1, 2], "deadline delivers the resolved part: \(o?.text ?? "nil") \(o?.failed ?? [])")
            f.reply(1, "tarde")
            lk.lock(); check(out?.text == "Feito.", "late reply ignored"); lk.unlock()
        }
        // 12. Join: a stop before a lower-case continuation is dropped (cut inside a sentence); real sentence ends stay.
        do {
            check(ChunkAssembler.joinTexts(["Então, acho que devíamos.", "mudar o fornecedor."]) == "Então, acho que devíamos mudar o fornecedor.", "mid-sentence stop dropped")
            check(ChunkAssembler.joinTexts(["Acabou.", "Depois falamos."]) == "Acabou. Depois falamos.", "capital keeps the stop")
            check(ChunkAssembler.joinTexts(["Acabou?", "mas não."]) == "Acabou? mas não.", "only a full stop is touched")
            check(ChunkAssembler.joinTexts(["Espera...", "e depois"]) == "Espera... e depois", "ellipsis kept")
            check(ChunkAssembler.joinTexts(["a", "b"]) == "a b" && ChunkAssembler.joinTexts([]) == "", "plain join")
        }
        // 13. Non-final segments are flagged partial, the tail is not; the session id travels on every request.
        do {
            let f = Fake(); let a = ChunkAssembler(chain: false, session: "abc", transport: f.transport)
            a.submit(wav: wav(1), cleanup: true); a.finish(tail: (wav(2), true)) { _ in }
            check(f.sent.map(\.partial) == [true, false] && f.sent.allSatisfy { $0.session == "abc" }, "partial flag and session id")
        }
        return ok
    }
}
