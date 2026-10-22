import AppKit

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func argValue(_ flag: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
    return a[i + 1]
}

func projectDir() -> String {
    if let p = argValue("--project") { return p }
    if let p = Bundle.main.object(forInfoDictionaryKey: "DictFlowProjectDir") as? String { return p }
    fail("no project dir: pass --project DIR (no DictFlowProjectDir in Info.plist)")
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "--convert":
    guard args.count >= 3 else { fail("usage: DictFlow --convert IN OUT") }
    do {
        let wav = try WavConverter.wav(from: URL(fileURLWithPath: args[1]))
        try wav.write(to: URL(fileURLWithPath: args[2]))
        print("wrote \(args[2]) (\(wav.count) bytes)")
    } catch { fail("convert failed: \(error.localizedDescription)") }

case "--pipeline-test":
    guard args.count >= 2 else { fail("usage: DictFlow --pipeline-test FILE [--project DIR]") }
    let client = WorkerClient(projectDir: projectDir())
    defer { client.shutdown() }
    do {
        let wav = try WavConverter.wav(from: URL(fileURLWithPath: args[1]))
        try client.ensureRunning()
        print(try client.transcribe(wav: wav))
    } catch {
        client.shutdown()
        fail("pipeline failed: \(error.localizedDescription)")
    }

case "--clipboard-test":
    if Inserter().selfTest() { print("PASS") } else { print("FAIL"); exit(1) }

case "--settings-test":
    if Settings.selfTest() { print("PASS") } else { print("FAIL"); exit(1) }

case "--hotkey-test":
    if HotkeyMachine.selfTest() { print("PASS") } else { print("FAIL"); exit(1) }

case "--shortcut-test":
    if PasteShortcut.selfTest() { print("PASS") } else { print("FAIL"); exit(1) }

case "--timinglog-test":
    if TimingLog.selfTest() { print("PASS") } else { print("FAIL"); exit(1) }

case "--chunking-test":
    let a = Segmenter.selfTest(), b = ChunkAssembler.selfTest(), c = ChunkSession.selfTest()
    if a && b && c { print("PASS") } else { print("FAIL"); exit(1) }

case "--segment":
    // DictFlow --segment FILE [--expect cuts.json]: print the cut times (seconds) the Segmenter finds; no worker needed.
    guard args.count >= 2 else { fail("usage: DictFlow --segment FILE") }
    do {
        let wav = try WavConverter.wav(from: URL(fileURLWithPath: args[1]))
        let r = Segmenter.cuts(pcm: wav.subdata(in: 44..<wav.count), config: Segmenter.Config.from(env: ProcessInfo.processInfo.environment))
        print("cuts: " + r.cuts.map { String(format: "%.3f", $0) }.joined(separator: " ") + String(format: "  tail_speech=%@ tail_s=%.2f total_s=%.2f", r.tailHasSpeech ? "yes" : "no", Double(r.tail.segment.pcm.count) / 32000, Double(wav.count - 44) / 32000))
    } catch { fail("segment failed: \(error.localizedDescription)") }

case "--chunk-sim":
    ChunkSim.main(args: args, projectDir: projectDir())

case "--check-permissions":
    let p = Permissions.status()
    print("microphone: \(p.mic)\naccessibility: \(p.accessibility ? "granted" : "not granted")\ninput-monitoring: \(p.inputMonitoring ? "granted" : "not granted")")

case nil:
    let app = NSApplication.shared
    let delegate = AppDelegate(projectDir: projectDir())
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()

default:
    print("""
    DictFlow - menu-bar dictation client
    Usage: DictFlow [--convert IN OUT | --pipeline-test FILE [--project DIR] | --clipboard-test | --settings-test | --hotkey-test | --shortcut-test | --timinglog-test | --chunking-test | --segment FILE | --chunk-sim FILE | --check-permissions]
    """)
}
