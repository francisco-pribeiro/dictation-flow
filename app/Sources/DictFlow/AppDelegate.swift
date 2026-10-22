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
    private let hotkey = HotkeyMonitor(name: ProcessInfo.processInfo.environment["DICTFLOW_HOTKEY"] ?? "rightoption")
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
