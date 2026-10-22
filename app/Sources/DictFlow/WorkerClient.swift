import Foundation

/// Talks to the local Python worker, spawning it via uv when it is not already healthy.
final class WorkerClient {
    let port: Int
    let projectDir: String
    private var child: Process?
    private let startLock = NSLock()   // serializes check/spawn/wait so a second caller waits instead of spawning
    private let childLock = NSLock()   // guards child; separate so Quit never waits for a 60 s startup

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
        startLock.lock(); defer { startLock.unlock() }
        if healthy() { return }
        guard let uv = uvPath() else {
            throw NSError(domain: "DictFlow", code: 4, userInfo: [NSLocalizedDescriptionKey: "uv not found in /opt/homebrew/bin or ~/.local/bin"])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "--project", projectDir, "dictflow", "serve", "--port", String(port)]
        p.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        try p.run()
        childLock.lock(); child = p; childLock.unlock()
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if !p.isRunning {
                childLock.lock(); if child === p { child = nil }; childLock.unlock()
                throw NSError(domain: "DictFlow", code: 5, userInfo: [NSLocalizedDescriptionKey: "worker exited with status \(p.terminationStatus)"])
            }
            if healthy() { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        shutdown()
        throw NSError(domain: "DictFlow", code: 6, userInfo: [NSLocalizedDescriptionKey: "worker not healthy after 60 s"])
    }

    /// Blocking. POST WAV bytes, return the text field.
    func transcribe(wav: Data, cleanup: Bool = true) throws -> String {
        var req = URLRequest(url: URL(string: "\(base)/transcribe\(cleanup ? "" : "?cleanup=0")")!)
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

    struct DictionaryInfo { let status: String; let path: String; let count: Int }

    /// Blocking. nil body = GET /dictionary; otherwise POST (add/ensure) with a JSON body. The worker owns the file logic.
    func dictionary(_ op: String? = nil, entry: String? = nil) throws -> DictionaryInfo {
        var req = URLRequest(url: URL(string: "\(base)/dictionary\(op.map { "/" + $0 } ?? "")")!)
        req.timeoutInterval = 5
        if let op {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: op == "add" ? ["entry": entry ?? ""] : [:])
        }
        let sem = DispatchSemaphore(value: 0)
        var result: Result<DictionaryInfo, Error> = .failure(NSError(domain: "DictFlow", code: 7))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { result = .failure(err); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            if code == 200, let path = obj?["path"] as? String {
                result = .success(DictionaryInfo(status: obj?["status"] as? String ?? "", path: path, count: obj?["count"] as? Int ?? 0))
            } else {
                result = .failure(NSError(domain: "DictFlow", code: code, userInfo: [NSLocalizedDescriptionKey: obj?["error"] as? String ?? "HTTP \(code)"]))
            }
        }.resume()
        sem.wait()
        return try result.get()
    }

    /// Terminate the child we spawned (a reused worker is left alone).
    func shutdown() {
        childLock.lock()
        let p = child
        child = nil
        childLock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
}
