import Foundation

/// Splits a live 16 kHz mono Int16 PCM stream into segments at pauses, so each segment can be sent to the
/// worker while the speaker is still talking. Pure value type: no I/O, no clock, no threads.
///
/// Rule (same idea as audio._speech_frames): a 30 ms frame is "loud" when its RMS is above
/// max(abs, floorK * noise floor, relK * recent peak). A loud run counts as speech once it lasts 3 frames
/// (90 ms), so clicks do not reset a pause. A segment closes when it holds at least `minSpeechMs` of speech
/// and the last speech ended `pauseMs` ago; the cut is at the middle of that pause, so no sample is lost or
/// duplicated and the cut is never inside speech.
struct Segmenter {
    struct Config: Equatable {
        var pauseMs = 450
        var minSpeechMs = 4000
        var absThreshold = 0.003
        var floorK = 3.0
        var relK = 0.04
        static let pauseRange = 350...500

        /// DICTFLOW_CHUNK_PAUSE_MS (clamped to 350-500) and DICTFLOW_CHUNK_MIN_MS (1000-10000).
        static func from(env: [String: String]) -> Config {
            var c = Config()
            if let v = env["DICTFLOW_CHUNK_PAUSE_MS"].flatMap({ Int($0) }) { c.pauseMs = min(max(v, pauseRange.lowerBound), pauseRange.upperBound) }
            if let v = env["DICTFLOW_CHUNK_MIN_MS"].flatMap({ Int($0) }) { c.minSpeechMs = min(max(v, 1000), 10000) }
            return c
        }
    }

    struct Segment: Equatable {
        let pcm: Data          // raw little-endian Int16 mono 16 kHz
        let startSample: Int   // position in the whole recording
        var endSample: Int { startSample + pcm.count / 2 }
    }

    struct Tail: Equatable {
        let segment: Segment
        let hasSpeech: Bool
    }

    static let frame = 480   // 30 ms at 16 kHz

    let config: Config
    private var seg: [Int16] = []
    private var segStart = 0          // recording position of seg[0]
    private var analysed = 0          // samples of seg already framed
    private var loudRun = 0
    private var speechFrames = 0
    private var lastSpeechEnd = -1    // index in seg just past the last confirmed speech frame
    private(set) var emitted = 0
    private var recent: [Double] = []         // ring of recent frame RMS for the noise-floor minimum
    private var recentPos = 0
    private var level = 0.0                   // recent peak frame RMS, slowly decaying
    private let floorWindow = 170             // about 5 s

    init(config: Config = Config()) { self.config = config }

    private var pauseFrames: Int { (config.pauseMs + 29) / 30 }
    private var minSpeechFrames: Int { (config.minSpeechMs + 29) / 30 }

    /// Current loud/quiet threshold, exposed for tests and tuning.
    var threshold: Double {
        let floor = min(recent.min() ?? 0, 0.02)
        return max(config.absThreshold, config.floorK * floor, config.relK * level)
    }

    /// Feed raw Int16 LE bytes; returns the segments this chunk closed (usually none).
    mutating func feed(_ pcm: Data) -> [Segment] {
        pcm.withUnsafeBytes { raw in
            let n = raw.count / 2
            seg.reserveCapacity(seg.count + n)
            for i in 0..<n { seg.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) }
        }
        var out: [Segment] = []
        while seg.count - analysed >= Segmenter.frame {
            let rms = frameRMS(analysed)
            let thr = threshold          // threshold from history, before this frame joins it
            analysed += Segmenter.frame
            if recent.count < floorWindow { recent.append(rms) } else { recent[recentPos] = rms; recentPos = (recentPos + 1) % floorWindow }
            level = max(rms, level * 0.9985)   // half-life about 15 s
            if rms > thr {
                loudRun += 1
                if loudRun == 3 { speechFrames += 3 } else if loudRun > 3 { speechFrames += 1 }
                if loudRun >= 3 { lastSpeechEnd = analysed }
            } else {
                loudRun = 0
            }
            if lastSpeechEnd >= 0, speechFrames >= minSpeechFrames, analysed - lastSpeechEnd >= pauseFrames * Segmenter.frame {
                let cut = lastSpeechEnd + (analysed - lastSpeechEnd) / 2
                out.append(take(cut))
            }
        }
        return out
    }

    /// End of recording: everything not yet emitted. `hasSpeech` is false for silence or a lone click.
    mutating func finish() -> Tail {
        let t = Tail(segment: Segment(pcm: bytes(seg[...]), startSample: segStart), hasSpeech: lastSpeechEnd >= 0)
        seg = []; analysed = 0
        return t
    }

    private mutating func take(_ cut: Int) -> Segment {
        let s = Segment(pcm: bytes(seg[0..<cut]), startSample: segStart)
        seg.removeFirst(cut)
        segStart += cut
        analysed -= cut
        speechFrames = 0; lastSpeechEnd = -1; loudRun = 0
        emitted += 1
        return s
    }

    private func frameRMS(_ at: Int) -> Double {
        var acc = 0.0
        for i in at..<(at + Segmenter.frame) { let v = Double(seg[i]) / 32768; acc += v * v }
        return (acc / Double(Segmenter.frame)).squareRoot()
    }

    private func bytes(_ s: ArraySlice<Int16>) -> Data {
        var d = Data(capacity: s.count * 2)
        for v in s { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        return d
    }

    // MARK: offline helpers (--segment, tests)

    /// Cut times in seconds for a whole PCM buffer fed in `bufferSamples` pieces, plus the tail decision.
    static func cuts(pcm: Data, config: Config = Config(), bufferSamples: Int = 1360) -> (cuts: [Double], tailHasSpeech: Bool, segments: [Segment], tail: Tail) {
        var s = Segmenter(config: config)
        var segs: [Segment] = []
        var off = 0
        while off < pcm.count {
            let end = min(off + bufferSamples * 2, pcm.count)
            segs += s.feed(pcm.subdata(in: off..<end))
            off = end
        }
        let t = s.finish()
        return (segs.map { Double($0.endSample) / 16000 }, t.hasSpeech, segs, t)
    }

    static func selfTest() -> Bool {
        var ok = true
        let tc = Config(minSpeechMs: 2500)   // the tests use 3 s utterances; the app default is 4 s
        func cuts(_ pcm: Data, _ b: Int = 1360) -> (cuts: [Double], tailHasSpeech: Bool, segments: [Segment], tail: Tail) {
            Segmenter.cuts(pcm: pcm, config: tc, bufferSamples: b)
        }
        func check(_ c: Bool, _ m: String) { if !c { ok = false; FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)) } }

        // Synthetic signal: 220 Hz tone with amplitude 0.2 for speech, low pseudo-noise for silence.
        var seed: UInt32 = 12345
        func noise() -> Double { seed = seed &* 1664525 &+ 1013904223; return (Double(seed >> 16) / 65535 - 0.5) * 0.004 }
        func sig(_ parts: [(Double, Bool)]) -> Data {
            var d = Data()
            var phase = 0.0
            for (secs, speech) in parts {
                for _ in 0..<Int(secs * 16000) {
                    phase += 2 * Double.pi * 220 / 16000
                    let v = speech ? 0.2 * sin(phase) * (0.7 + 0.3 * sin(phase * 0.01)) + noise() : noise()
                    var s = Int16(max(-1, min(1, v)) * 32767).littleEndian
                    withUnsafeBytes(of: &s) { d.append(contentsOf: $0) }
                }
            }
            return d
        }
        func concat(_ r: (cuts: [Double], tailHasSpeech: Bool, segments: [Segment], tail: Tail)) -> Data {
            var d = Data(); for s in r.segments { d.append(s.pcm) }; d.append(r.tail.segment.pcm); return d
        }

        // 1. No pauses: one segment, bytes equal to the whole recording (what recorder.stop() wraps in a WAV).
        let cont = sig([(0.5, false), (8, true), (0.3, false)])
        var r = cuts(cont)
        check(r.cuts.isEmpty, "no pauses gives no cut, got \(r.cuts)")
        check(r.tail.segment.pcm == cont && r.tail.hasSpeech, "single segment equals full recording")
        check(WavFormat.wav(fromPCM: r.tail.segment.pcm) == WavFormat.wav(fromPCM: cont), "single segment WAV identical")

        // 2. 300 ms pause inside speech: no cut. 500 ms: cut, inside the pause, nothing lost.
        let short = sig([(3, true), (0.3, false), (3, true)])
        r = cuts(short)
        check(r.cuts.isEmpty, "300 ms pause must not cut, got \(r.cuts)")
        let long = sig([(3, true), (0.5, false), (3, true)])
        r = cuts(long)
        check(r.cuts.count == 1 && r.cuts[0] > 3.0 && r.cuts[0] < 3.5, "500 ms pause cuts inside the pause, got \(r.cuts)")
        check(concat(r) == long, "segments concatenate to the input exactly")

        // 3. 700 ms pause then more speech: cut at the middle of the detected pause.
        let mid = sig([(3, true), (0.7, false), (3, true)])
        r = cuts(mid)
        check(r.cuts.count == 1 && r.cuts[0] > 3.0 && r.cuts[0] < 3.7, "700 ms cut inside pause, got \(r.cuts)")
        check(concat(r) == mid, "700 ms: concatenation exact")

        // 4. Pause at the very end: the cut closes the speech, the leftover silence is not a segment worth sending.
        let endp = sig([(3, true), (0.7, false)])
        r = cuts(endp)
        check(r.cuts.count == 1 && !r.tailHasSpeech, "pause at end: one segment, tail has no speech (cuts \(r.cuts), speech \(r.tailHasSpeech))")
        check(concat(r) == endp, "pause at end: concatenation exact")

        // 5. Short first sentence (under the minimum speech) is not cut off alone.
        let tiny = sig([(1.5, true), (0.8, false), (3, true)])
        r = cuts(tiny)
        check(r.cuts.isEmpty, "1.5 s of speech is below the minimum, got \(r.cuts)")

        // 6. Silence only: no cut, tail has no speech, bytes kept (so main's path sees the same audio).
        let quiet = sig([(2, false)])
        r = cuts(quiet)
        check(r.cuts.isEmpty && !r.tailHasSpeech && r.tail.segment.pcm == quiet, "silence only")

        // 7. Many pauses, odd buffer sizes: always an exact partition, same cuts for any buffer size.
        let many = sig([(0.3, false), (3, true), (0.6, false), (3, true), (0.9, false), (3, true), (0.2, false), (3, true), (1.0, false)])
        let ref = cuts(many)
        check(ref.cuts.count == 3, "three long pauses give three cuts, got \(ref.cuts)")
        for b in [1, 7, 480, 1000, 4096, 16000] {
            let x = cuts(many, b)
            check(x.cuts == ref.cuts, "buffer size \(b) changes the cuts: \(x.cuts) vs \(ref.cuts)")
            check(concat(x) == many, "buffer size \(b) loses or duplicates samples")
        }

        // 8. A 40 ms click inside a pause is not speech and does not delay the cut.
        var clickSig = sig([(3, true), (0.2, false)])
        clickSig.append(sig([(0.04, true)]))
        clickSig.append(sig([(0.6, false), (3, true)]))
        r = cuts(clickSig)
        check(r.cuts.count == 1, "click in pause: still one cut, got \(r.cuts)")

        // 8b. App default (4 s): a 3 s first utterance is not cut off alone, it is merged into the next segment.
        check(Config().minSpeechMs == 4000, "default minimum speech is 4 s")
        r = Segmenter.cuts(pcm: sig([(3, true), (0.7, false), (3, true), (0.7, false), (1, true)]))
        check(r.cuts.count == 1 && r.cuts[0] > 6.5, "3 s utterance merged into the next: cuts \(r.cuts)")

        // 9. Env parsing clamps the pause.
        check(Config.from(env: ["DICTFLOW_CHUNK_PAUSE_MS": "100"]).pauseMs == 350, "pause clamped low")
        check(Config.from(env: ["DICTFLOW_CHUNK_PAUSE_MS": "9000"]).pauseMs == 500, "pause clamped high")
        check(Config.from(env: ["DICTFLOW_CHUNK_PAUSE_MS": "x"]).pauseMs == 450, "garbage gives default")
        check(Config.from(env: [:]) == Config(), "default config")
        return ok
    }
}
