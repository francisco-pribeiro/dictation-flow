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
    Usage: DictFlow [--convert IN OUT | --pipeline-test FILE [--project DIR] | --clipboard-test | --settings-test | --hotkey-test | --shortcut-test | --check-permissions]
    """)
}
