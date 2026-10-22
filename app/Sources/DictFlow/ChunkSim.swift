import Foundation

/// Headless latency simulation: streams a WAV at real-time pace through the real Segmenter, ChunkAssembler
/// and WorkerClient (against a worker on DICTFLOW_PORT), and measures release (end of the audio) until the
/// assembled text is ready. Paste is not included (the owner measures 10-50 ms). `single` sends the whole WAV
/// at release, like main.
enum ChunkSim {
    struct RunResult { let mode: String; let waitMs: Double; let segments: Int; let tailAudio: Double; let tailRequestMs: Double; let text: String; let failed: Int }

    static func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b &- a) / 1e6 }

    static func pcm(of wav: Data) -> Data { wav.subdata(in: 44..<wav.count) }

    static func sleep(until t: UInt64) {
        while true {
            let n = DispatchTime.now().uptimeNanoseconds
            if n >= t { return }
            Thread.sleep(forTimeInterval: Double(t - n) / 1e9)
        }
    }

    static func runChunked(wav: Data, worker: WorkerClient, config: Segmenter.Config, chain: Bool, bufferSamples: Int = 1360) -> RunResult {
        let data = pcm(of: wav)
        let session = ChunkSession(config: config, chain: chain, secureCheck: { false }, transport: worker.chunkTransport())
        let t0 = DispatchTime.now().uptimeNanoseconds
        var off = 0
        while off < data.count {
            let end = min(off + bufferSamples * 2, data.count)
            sleep(until: t0 + UInt64(Double(end / 2) / 16000 * 1e9))   // a buffer arrives once it has been recorded
            session.feed(data.subdata(in: off..<end))
            off = end
        }
        let release = DispatchTime.now().uptimeNanoseconds
        let sem = DispatchSemaphore(value: 0)
        var res: ChunkSession.Result?
        session.finish(secureAtRelease: false) { res = $0; sem.signal() }
        sem.wait()
        let done = DispatchTime.now().uptimeNanoseconds
        let o = res!.outcome
        return RunResult(mode: "chunked", waitMs: ms(release, done), segments: o.segments, tailAudio: res!.tailAudio,
                         tailRequestMs: ms(o.lastSentNs, o.lastDoneNs), text: o.text, failed: o.failed.count)
    }

    static func runSingle(wav: Data, worker: WorkerClient, bufferSamples: Int = 1360) -> RunResult {
        let n = (wav.count - 44) / 2
        let t0 = DispatchTime.now().uptimeNanoseconds
        sleep(until: t0 + UInt64(Double(n) / 16000 * 1e9))   // the audio plays out in real time, then release
        let release = DispatchTime.now().uptimeNanoseconds
        var text = "", failed = 0
        do {
            try worker.ensureRunning()
            text = try worker.transcribe(wav: wav, cleanup: true).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { failed = 1 }
        let done = DispatchTime.now().uptimeNanoseconds
        return RunResult(mode: "single", waitMs: ms(release, done), segments: 1, tailAudio: Double(n) / 16000, tailRequestMs: ms(release, done), text: text, failed: failed)
    }

    static func stats(_ v: [Double]) -> String {
        guard !v.isEmpty else { return "n=0" }
        let s = v.sorted()
        let med = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        return String(format: "median=%.0f min=%.0f max=%.0f n=%d", med, s.first!, s.last!, s.count)
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted(); return s.isEmpty ? 0 : (s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2)
    }

    /// `--chunk-sim FILE [--ab N | --single | --runs N] [--out DIR] [--no-context] [--project DIR]`
    static func main(args: [String], projectDir: String) {
        guard args.count >= 2 else { fail("usage: DictFlow --chunk-sim FILE [--ab N | --single | --runs N] [--out DIR] [--no-context]") }
        let env = ProcessInfo.processInfo.environment
        let worker = WorkerClient(projectDir: projectDir)
        let wav: Data
        do { wav = try WavConverter.wav(from: URL(fileURLWithPath: args[1])); try worker.ensureRunning() } catch { fail("chunk-sim setup failed: \(error.localizedDescription)") }
        let cfg = Segmenter.Config.from(env: env)
        let chain = !args.contains("--no-context") && env["DICTFLOW_CHUNK_CONTEXT"] != "0"
        let outDir = argValue("--out")
        if let outDir { try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        let dur = Double(wav.count - 44) / 32000
        print(String(format: "audio=%.1fs pause=%dms min_speech=%dms context_chain=%@", dur, cfg.pauseMs, cfg.minSpeechMs, chain ? "on" : "off"))

        var plan: [String] = []
        if let n = argValue("--ab").flatMap({ Int($0) }) {
            plan = ["single!", "chunked!"]   // "!" = discarded warm-up
            for _ in 0..<n { plan += ["single", "chunked"] }
        } else {
            let n = argValue("--runs").flatMap({ Int($0) }) ?? 1
            let m = args.contains("--single") ? "single" : "chunked"
            plan = Array(repeating: m, count: n)
        }
        var results: [String: [RunResult]] = [:]
        var idx: [String: Int] = [:]
        for step in plan {
            let warm = step.hasSuffix("!")
            let mode = warm ? String(step.dropLast()) : step
            let r = mode == "single" ? runSingle(wav: wav, worker: worker) : runChunked(wav: wav, worker: worker, config: cfg, chain: chain)
            let i = idx[mode, default: 0]; idx[mode] = i + 1
            print(String(format: "%@ %@ wait_ms=%.0f segments=%d tail_audio=%.1fs tail_request_ms=%.0f chars=%d failed=%d",
                         warm ? "warmup" : "run", mode, r.waitMs, r.segments, r.tailAudio, r.tailRequestMs, r.text.count, r.failed))
            if !warm {
                results[mode, default: []].append(r)
                if let outDir { try? r.text.write(toFile: "\(outDir)/\(mode)_\(i).txt", atomically: true, encoding: .utf8) }
            }
        }
        for mode in ["single", "chunked"] where results[mode] != nil {
            print("summary \(mode) wait_ms \(stats(results[mode]!.map(\.waitMs)))")
        }
        if let s = results["single"], let c = results["chunked"] {
            print(String(format: "ratio chunked/single (median) = %.3f", median(c.map(\.waitMs)) / median(s.map(\.waitMs))))
        }
    }
}
