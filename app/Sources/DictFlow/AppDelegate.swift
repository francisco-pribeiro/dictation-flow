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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case idle, recording, working }

    private let worker: WorkerClient
    private let recorder = AudioRecorder()
    private let inserter = Inserter()
    private var settings = Settings.load()
    private lazy var hotkey = HotkeyMonitor(key: Hotkeys.resolve(settings: settings, env: ProcessInfo.processInfo.environment["DICTFLOW_HOTKEY"]))
    private let hotkeyMenu = NSMenu()
    private let hotkeyItem = NSMenuItem(title: "Atalho", action: nil, keyEquivalent: "")
    private var capturing = false
    private lazy var pasteMonitor = PasteShortcutMonitor(shortcut: PasteShortcut.resolve(settings: settings))
    private var pasteOK = false
    private var capturingPaste = false
    private var latched = false
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let transcriptItem = NSMenuItem(title: "No transcript yet", action: #selector(copyTranscript), keyEquivalent: "")
    private let warningItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let dictItem = NSMenuItem(title: "Dicionario", action: nil, keyEquivalent: "")
    private let dictMenu = NSMenu()
    private let dictCountItem = NSMenuItem(title: "Dicionario: ...", action: nil, keyEquivalent: "")
    private var lastTranscript = ""
    private var state = State.idle { didSet { if state != .recording { latched = false }; refreshTitle() } }
    private var tapOK = false
    private var signalSources: [DispatchSourceSignal] = []

    init(projectDir: String) { worker = WorkerClient(projectDir: projectDir) }

    func applicationDidFinishLaunching(_ n: Notification) {
        installEditMenu()
        let menu = NSMenu()
        transcriptItem.target = self
        warningItem.isHidden = true
        warningItem.isEnabled = false
        let check = NSMenuItem(title: "Check permissions", action: #selector(checkPermissions), keyEquivalent: "")
        check.target = self
        menu.addItem(transcriptItem)
        menu.addItem(warningItem)
        menu.addItem(check)
        for (title, sel) in [("Colar ultima transcricao", #selector(pasteLastFromMenu)), ("Copiar ultima transcricao", #selector(copyTranscript))] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)
        dictCountItem.isEnabled = false
        dictMenu.addItem(dictCountItem)
        for (title, sel) in [("Adicionar ao dicionario...", #selector(addDictionaryEntry)), ("Abrir dicionario", #selector(openDictionary))] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            dictMenu.addItem(mi)
        }
        dictItem.submenu = dictMenu
        menu.addItem(dictItem)
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        inserter.onFallback = { [weak self] msg in
            self?.warningItem.title = msg
            self?.warningItem.isHidden = false
        }
        hotkey.onStart = { [weak self] in self?.startRecording() ?? false }
        hotkey.onLatch = { [weak self] in self?.enterLatched() }
        hotkey.isBusy = { [weak self] in self?.state != .idle }
        pasteMonitor.onFire = { [weak self] in
            self?.hotkey.cancelHold()   // the shortcut may use the push-to-talk modifier: drop that hold first
            self?.pasteLast(delay: 0, waitForModifiers: true)
        }
        pasteMonitor.onCaptured = { [weak self] s in self?.capturedPaste(s) }
        pasteMonitor.onCaptureCancelled = { [weak self] in self?.capturingPaste = false; self?.rebuildHotkeyMenu() }
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

    /// An accessory app never shows its main menu, but it still routes these key equivalents, so Cmd+V/C/X/A/Z
    /// work in the dictionary dialog's text field.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu()
        main.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Editar")
        for (title, sel, key, mods) in [("Anular", "undo:", "z", NSEvent.ModifierFlags.command), ("Refazer", "redo:", "z", [.command, .shift]),
                                        ("Cortar", "cut:", "x", .command), ("Copiar", "copy:", "c", .command),
                                        ("Colar", "paste:", "v", .command), ("Selecionar tudo", "selectAll:", "a", .command)] {
            let mi = NSMenuItem(title: title, action: Selector(sel), keyEquivalent: key)
            mi.keyEquivalentModifierMask = mods
            edit.addItem(mi)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
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
        pasteOK = pasteMonitor.start()
        if !pasteOK { log("paste shortcut tap could not be created (needs Accessibility)") }
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
        if !pasteOK { pasteOK = pasteMonitor.start() }
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

        // Shortcut that re-pastes the last transcript
        hotkeyMenu.addItem(.separator())
        let pasteCur = currentPasteShortcut
        let header = NSMenuItem(title: "Colar ultima transcricao: \(capturingPaste ? "a gravar..." : pasteCur.label)" + (pasteOK ? "" : " (inativo)"),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        hotkeyMenu.addItem(header)
        var shortcuts = PasteShortcut.presets
        if !shortcuts.contains(pasteCur) { shortcuts.insert(pasteCur, at: 0) }
        for sc in shortcuts {
            let mi = NSMenuItem(title: sc.label, action: #selector(pickPasteShortcut(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = sc.name
            mi.state = sc == pasteCur ? .on : .off
            hotkeyMenu.addItem(mi)
        }
        let recPaste = NSMenuItem(title: capturingPaste ? "A gravar: prima modificador + letra (Esc cancela)" : "Gravar novo atalho de colar...",
                                  action: capturingPaste ? nil : #selector(recordPasteShortcut), keyEquivalent: "")
        recPaste.target = self
        hotkeyMenu.addItem(recPaste)
    }

    private var currentPasteShortcut: PasteShortcut { PasteShortcut.resolve(settings: settings) }

    private func applyPaste(_ sc: PasteShortcut) {
        settings.pasteShortcut = sc.name
        do { try settings.save() } catch { log("could not save settings: \(error.localizedDescription)") }
        pasteMonitor.setShortcut(sc)
        rebuildHotkeyMenu()
    }

    @objc private func pickPasteShortcut(_ sender: NSMenuItem) {
        guard let sc = PasteShortcut.parse(sender.representedObject as? String) else { return }
        if capturingPaste { pasteMonitor.endCapture(); capturingPaste = false }
        applyPaste(sc)
    }

    @objc private func recordPasteShortcut() {
        guard pasteOK else { NSSound.beep(); return }
        if capturing { hotkey.endCapture(); capturing = false }
        capturingPaste = true
        pasteMonitor.beginCapture()
        rebuildHotkeyMenu()
    }

    private func capturedPaste(_ sc: PasteShortcut) {
        capturingPaste = false
        applyPaste(sc)
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
        if capturingPaste { pasteMonitor.endCapture(); capturingPaste = false }
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
        item.button?.title = !tapOK || !Permissions.missing().isEmpty ? "!" : state == .idle ? "◦" : state == .recording ? (latched ? "◉" : "●") : "…"
    }

    /// Returns false when recording did not begin.
    private func startRecording() -> Bool {
        guard state == .idle else { return false }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            NSSound.beep(); refreshWarning(); refreshTitle()
            return false
        }
        do {
            try recorder.start()
            state = .recording
            return true
        } catch {
            _ = recorder.stop()
            log("recorder start failed: \(error.localizedDescription)")
            NSSound.beep()
            return false
        }
    }

    /// Double-tap: keep recording without holding the key. Icon and a short sound make it obvious.
    private func enterLatched() {
        guard state == .recording else { return }
        latched = true
        refreshTitle()
        NSSound(named: "Tink")?.play()
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()   // engine stops so the mic indicator goes off
        state = .idle
    }

    private func stopRecording() {
        guard state == .recording else { return }
        let tRelease = DispatchTime.now().uptimeNanoseconds
        let wav = recorder.stop()
        state = .working
        let secure = Inserter.secureInputOnFrontmost()   // decide before any text leaves the machine
        DispatchQueue.global().async { [self] in
            do {
                try worker.ensureRunning()
                let tSend = DispatchTime.now().uptimeNanoseconds
                let text = try worker.transcribe(wav: wav, cleanup: !secure).trimmingCharacters(in: .whitespacesAndNewlines)
                let tResp = DispatchTime.now().uptimeNanoseconds
                let meta = worker.lastMeta
                DispatchQueue.main.async { [self] in
                    state = .idle
                    guard !text.isEmpty else { NSSound.beep(); return }   // no speech detected
                    lastTranscript = text
                    transcriptItem.title = "Last: " + (text.count > 50 ? String(text.prefix(50)) + "…" : text)
                    inserter.insert(text)
                    let tPaste = DispatchTime.now().uptimeNanoseconds
                    let ms = { (a: UInt64, b: UInt64) in (b - a) / 1_000_000 }
                    let audio = Double(max(wav.count - 44, 0)) / 32000   // 16 kHz mono Int16
                    log("timing release->send=\(ms(tRelease, tSend))ms request=\(ms(tSend, tResp))ms paste=\(ms(tResp, tPaste))ms total=\(ms(tRelease, tPaste))ms audio=\(String(format: "%.1f", audio))s")
                    // After paste and state == .idle; formatting is a few microseconds, I/O runs on a utility queue.
                    TimingLog.record(audio: audio, chars: text.count, meta: meta,
                                     sendMs: ms(tRelease, tSend), requestMs: ms(tSend, tResp), pasteMs: ms(tResp, tPaste), totalMs: ms(tRelease, tPaste))
                }
            } catch {
                log("transcribe failed: \(error.localizedDescription)")
                DispatchQueue.main.async { [self] in state = .idle; NSSound.beep() }
            }
        }
    }

    // MARK: dictionary

    /// Refreshes the entry count each time the menu opens (the file may have been edited by hand).
    func menuWillOpen(_ menu: NSMenu) { refreshDictionaryCount() }

    private func refreshDictionaryCount() {
        DispatchQueue.global().async { [worker] in
            let info = try? worker.dictionary()
            DispatchQueue.main.async { [self] in setDictionaryCount(info?.count) }
        }
    }

    private func setDictionaryCount(_ n: Int?) {
        let t = n.map { "\($0) \($0 == 1 ? "entrada" : "entradas")" }
        dictItem.title = t.map { "Dicionario: \($0)" } ?? "Dicionario"
        dictCountItem.title = t ?? "Worker indisponivel"
    }

    @objc private func addDictionaryEntry() {
        let alert = NSAlert()
        alert.messageText = "Adicionar ao dicionario"
        alert.informativeText = "Um termo (Supabase) ou uma correcao (super base -> Supabase)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Adicionar")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        let prev = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        prev?.activate()   // give focus back, or the next paste finds DictFlow frontmost
        guard resp == .alertFirstButtonReturn else { return }
        let entry = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return }
        DispatchQueue.global().async { [self] in
            do {
                try worker.ensureRunning()
                let info = try worker.dictionary("add", entry: entry)
                log("dictionary: \(info.status), \(info.count) entries")
                DispatchQueue.main.async { [self] in
                    setDictionaryCount(info.count)
                    if info.status == "exists" { NSSound.beep() }   // already there: nothing changed
                }
            } catch {
                log("dictionary add failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    let a = NSAlert()
                    a.messageText = "Nao foi possivel adicionar"
                    a.informativeText = error.localizedDescription
                    let prev = NSWorkspace.shared.frontmostApplication
                    NSApp.activate(ignoringOtherApps: true)
                    a.runModal()
                    prev?.activate()
                }
            }
        }
    }

    @objc private func openDictionary() {
        DispatchQueue.global().async { [self] in
            do {
                try worker.ensureRunning()
                let info = try worker.dictionary("ensure")
                DispatchQueue.main.async { [self] in
                    setDictionaryCount(info.count)
                    NSWorkspace.shared.open(URL(fileURLWithPath: info.path))
                }
            } catch {
                log("dictionary open failed: \(error.localizedDescription)")
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
    }

    @objc private func pasteLastFromMenu() { pasteLast(delay: 0.3) }   // let the menu close first

    /// Re-pastes the last final text (memory only) through the normal clipboard-restore paste path.
    /// `waitForModifiers`: the shortcut fires on key-down with Cmd/Ctrl still held, which would turn the
    /// synthetic Cmd-V into Ctrl+Cmd+V; wait (up to 1 s) until they are released.
    private func pasteLast(delay: TimeInterval, waitForModifiers: Bool = false) {
        guard !lastTranscript.isEmpty, state == .idle else { NSSound.beep(); return }
        let text = lastTranscript
        let deadline = Date().addingTimeInterval(1)
        func go() {
            let held = CGEventSource.flagsState(.combinedSessionState).rawValue & PasteShortcut.modMask != 0
            if waitForModifiers, held, Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { go() }
            } else if state == .idle {
                inserter.insert(text)
            } else { NSSound.beep() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { go() }
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
