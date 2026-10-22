import AppKit
import AVFoundation

enum Permissions {
    static func status() -> (mic: String, accessibility: Bool, inputMonitoring: Bool) {
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "granted"
        case .notDetermined: mic = "not determined"
        case .denied: mic = "denied"
        case .restricted: mic = "restricted"
        @unknown default: mic = "unknown"
        }
        return (mic, AXIsProcessTrusted(), CGPreflightListenEventAccess())
    }

    static func missing() -> [String] {
        let s = status()
        var m: [String] = []
        if s.mic != "granted" { m.append("Microphone") }
        if !s.accessibility { m.append("Accessibility") }
        if !s.inputMonitoring { m.append("Input Monitoring") }
        return m
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State { case idle, recording, working }

    private let worker: WorkerClient
    private let recorder = AudioRecorder()
    private let inserter = Inserter()
    private var settings = Settings.load()
    private lazy var hotkey = HotkeyMonitor(key: Hotkeys.resolve(settings: settings, env: ProcessInfo.processInfo.environment["DICTFLOW_HOTKEY"]))
    private let hotkeyMenu = NSMenu()
    private let hotkeyItem = NSMenuItem(title: "Atalho", action: nil, keyEquivalent: "")
    private var capturing = false
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let transcriptItem = NSMenuItem(title: "No transcript yet", action: #selector(copyTranscript), keyEquivalent: "")
    private let warningItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var lastTranscript = ""
    private var state = State.idle { didSet { refreshTitle() } }
    private var tapOK = false
    private var signalSources: [DispatchSourceSignal] = []

    init(projectDir: String) { worker = WorkerClient(projectDir: projectDir) }

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        transcriptItem.target = self
        warningItem.isHidden = true
        warningItem.isEnabled = false
        let check = NSMenuItem(title: "Check permissions", action: #selector(checkPermissions), keyEquivalent: "")
        check.target = self
        menu.addItem(transcriptItem)
        menu.addItem(warningItem)
        menu.addItem(check)
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        inserter.onFallback = { [weak self] msg in
            self?.warningItem.title = msg
            self?.warningItem.isHidden = false
        }
        hotkey.onStart = { [weak self] in self?.startRecording() }
        hotkey.onStop = { [weak self] in self?.stopRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }
        hotkey.onCaptured = { [weak self] k in self?.captured(k) }
        hotkey.onCaptureCancelled = { [weak self] in self?.capturing = false; self?.rebuildHotkeyMenu() }
        rebuildHotkeyMenu()

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }

        requestPermissions()
        DispatchQueue.global().async { [worker] in
            do { try worker.ensureRunning(); log("worker ready") } catch { log("worker failed: \(error.localizedDescription)") }
        }
    }

    func applicationWillTerminate(_ n: Notification) { worker.shutdown() }

    // MARK: permissions

    private func requestPermissions() {
        let s = Permissions.status()
        log("microphone=\(s.mic) accessibility=\(s.accessibility) input-monitoring=\(s.inputMonitoring)")
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                log("microphone request: \(ok)")
                DispatchQueue.main.async { self?.refreshWarning(); self?.refreshTitle() }
            }
        }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        tapOK = hotkey.start()
        if !tapOK { log("event tap could not be created") }
        refreshWarning()
        refreshTitle()
    }

    private func refreshWarning() {
        let missing = Permissions.missing()
        warningItem.isHidden = missing.isEmpty && tapOK
        warningItem.title = tapOK ? "Missing: \(missing.joined(separator: ", "))"
            : "Hotkey off: grant Input Monitoring, then Check permissions (\(missing.joined(separator: ", ")))"
    }

    @objc private func checkPermissions() {
        let s = Permissions.status()
        log("microphone=\(s.mic) accessibility=\(s.accessibility) input-monitoring=\(s.inputMonitoring)")
        if !tapOK { tapOK = hotkey.start() }
        refreshWarning()
        refreshTitle()
    }

    // MARK: hotkey picker

    private var currentKey: HotkeyKey { Hotkeys.resolve(settings: settings, env: ProcessInfo.processInfo.environment["DICTFLOW_HOTKEY"]) }

    private func rebuildHotkeyMenu() {
        hotkeyMenu.removeAllItems()
        let cur = currentKey
        hotkeyItem.title = capturing ? "Atalho: a gravar..." : "Atalho: \(cur.label)"
        var keys = Hotkeys.presets
        if !keys.contains(cur) { keys.insert(cur, at: 0) }   // a recorded non-preset key
        for k in keys {
            let mi = NSMenuItem(title: k.label, action: #selector(pickHotkey(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = k.name
            mi.state = k == cur ? .on : .off
            hotkeyMenu.addItem(mi)
        }
        hotkeyMenu.addItem(.separator())
        let rec = NSMenuItem(title: capturing ? "A gravar: prime uma tecla modificadora (Esc cancela)" : "Gravar novo atalho...",
                             action: capturing ? nil : #selector(recordHotkey), keyEquivalent: "")
        rec.target = self
        hotkeyMenu.addItem(rec)
    }

    private func apply(_ k: HotkeyKey) {
        settings.hotkey = k.name
        do { try settings.save() } catch { log("could not save settings: \(error.localizedDescription)") }
        hotkey.setKey(k)
        rebuildHotkeyMenu()
    }

    @objc private func pickHotkey(_ sender: NSMenuItem) {
        guard let k = Hotkeys.key(named: sender.representedObject as? String) else { return }
        if capturing { hotkey.endCapture(); capturing = false }
        apply(k)
    }

    @objc private func recordHotkey() {
        guard tapOK else { NSSound.beep(); return }   // the capture needs the event tap
        capturing = true
        hotkey.beginCapture()
        rebuildHotkeyMenu()
    }

    private func captured(_ k: HotkeyKey) {
        capturing = false
        apply(k)
    }

    // MARK: flow

    private func refreshTitle() {
        item.button?.title = !tapOK || !Permissions.missing().isEmpty ? "!" : state == .idle ? "◦" : state == .recording ? "●" : "…"
    }

    private func startRecording() {
        guard state == .idle else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            NSSound.beep(); refreshWarning(); refreshTitle()
            return
        }
        do {
            try recorder.start()
            state = .recording
        } catch {
            _ = recorder.stop()
            log("recorder start failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()   // engine stops so the mic indicator goes off
        state = .idle
    }

    private func stopRecording() {
        guard state == .recording else { return }
        let wav = recorder.stop()
        state = .working
        let secure = Inserter.secureInputOnFrontmost()   // decide before any text leaves the machine
        DispatchQueue.global().async { [self] in
            do {
                try worker.ensureRunning()
                let text = try worker.transcribe(wav: wav, cleanup: !secure).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async { [self] in
                    state = .idle
                    guard !text.isEmpty else { NSSound.beep(); return }   // no speech detected
                    lastTranscript = text
                    transcriptItem.title = "Last: " + (text.count > 50 ? String(text.prefix(50)) + "…" : text)
                    inserter.insert(text)
                }
            } catch {
                log("transcribe failed: \(error.localizedDescription)")
                DispatchQueue.main.async { [self] in state = .idle; NSSound.beep() }
            }
        }
    }

    @objc private func copyTranscript() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }
}

func log(_ msg: String) {
    FileHandle.standardError.write(Data(("[dictflow] " + msg + "\n").utf8))
}
