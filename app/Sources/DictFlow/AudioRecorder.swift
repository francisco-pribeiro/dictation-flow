import AVFoundation

/// Records the default input device into 16 kHz mono Int16 WAV, in memory.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var pcm = Data()
    private var converter: AVAudioConverter?
    private var running = false

    func start() throws {
        lock.lock(); pcm = Data(); lock.unlock()
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: hw, to: WavFormat.target) else {
            throw NSError(domain: "DictFlow", code: 3, userInfo: [NSLocalizedDescriptionKey: "no usable input format"])
        }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { [weak self] buf, _ in
            guard let self, let conv = self.converter else { return }
            var chunk = Data()
            try? WavFormat.convert(conv, input: buf, into: &chunk)
            self.lock.lock(); self.pcm.append(chunk); self.lock.unlock()
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)   // else the next installTap raises an NSException
            converter = nil
            throw error
        }
        running = true
    }

    func stop() -> Data {
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
        }
        lock.lock(); defer { lock.unlock() }
        return WavFormat.wav(fromPCM: pcm)
    }
}
