import Foundation

/// Talks to the local Python worker, spawning it via uv when it is not already healthy.
final class WorkerClient {
    let port: Int
    let projectDir: String
    private var child: Process?

    init(projectDir: String) {
        self.projectDir = projectDir
        self.port = Int(ProcessInfo.processInfo.environment["DICTFLOW_PORT"] ?? "") ?? 8765
    }

    private var base: String { "http://127.0.0.1:\(port)" }

    private func healthy() -> Bool {
        var req = URLRequest(url: URL(string: "\(base)/health")!)
        req.timeoutInterval = 1
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = (resp as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }.resume()
        sem.wait()
        return ok
    }

    private func uvPath() -> String? {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin/uv", "\(home)/.local/bin/uv", "/usr/local/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Blocking. Reuses a healthy worker, otherwise spawns one and waits up to 60 s.
    func ensureRunning() throws {
        if healthy() { return }
        guard let uv = uvPath() else {
            throw NSError(domain: "DictFlow", code: 4, userInfo: [NSLocalizedDescriptionKey: "uv not found in /opt/homebrew/bin or ~/.local/bin"])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "--project", projectDir, "dictflow", "serve"]
        p.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        try p.run()
        child = p
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if !p.isRunning {
                child = nil
                throw NSError(domain: "DictFlow", code: 5, userInfo: [NSLocalizedDescriptionKey: "worker exited with status \(p.terminationStatus)"])
            }
            if healthy() { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        shutdown()
        throw NSError(domain: "DictFlow", code: 6, userInfo: [NSLocalizedDescriptionKey: "worker not healthy after 60 s"])
    }

    /// Blocking. POST WAV bytes, return the text field.
    func transcribe(wav: Data) throws -> String {
        var req = URLRequest(url: URL(string: "\(base)/transcribe")!)
        req.httpMethod = "POST"
        req.httpBody = wav
        req.timeoutInterval = 15
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let sem = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .failure(NSError(domain: "DictFlow", code: 7))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { result = .failure(err); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            if code == 200, let text = obj?["text"] as? String { result = .success(text) }
            else {
                let msg = obj?["error"] as? String ?? "HTTP \(code)"
                result = .failure(NSError(domain: "DictFlow", code: code, userInfo: [NSLocalizedDescriptionKey: msg]))
            }
        }.resume()
        sem.wait()
        return try result.get()
    }

    /// Terminate the child we spawned (a reused worker is left alone).
    func shutdown() {
        guard let p = child, p.isRunning else { child = nil; return }
        p.terminate()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        child = nil
    }
}
