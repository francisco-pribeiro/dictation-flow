import AVFoundation

/// Shared 16 kHz mono Int16 conversion used by the recorder and --convert.
enum WavFormat {
    static let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    /// Wrap raw little-endian Int16 mono 16 kHz PCM in a RIFF/WAVE header.
    static func wav(fromPCM pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }

    /// Convert one buffer, appending Int16 bytes to `out`. `flush` signals end of stream.
    static func convert(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, into out: inout Data) throws {
        let ratio = 16000 / converter.inputFormat.sampleRate
        let inFrames = Double(input?.frameLength ?? 0)
        let cap = AVAudioFrameCount(inFrames * ratio) + 1024
        guard let dst = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: dst, error: &err) { _, st in
            if let input, !fed {
                fed = true
                st.pointee = .haveData
                return input
            }
            st.pointee = input == nil ? .endOfStream : .noDataNow
            return nil
        }
        if status == .error { throw err ?? NSError(domain: "DictFlow", code: 1) }
        if let p = dst.int16ChannelData?[0], dst.frameLength > 0 {
            out.append(UnsafeBufferPointer(start: p, count: Int(dst.frameLength)))
        }
    }
}

enum WavConverter {
    /// Read any AVAudioFile-readable file and return a 16 kHz mono Int16 WAV.
    static func wav(from url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        guard let conv = AVAudioConverter(from: fmt, to: WavFormat.target) else {
            throw NSError(domain: "DictFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: "unsupported audio format"])
        }
        var pcm = Data()
        let chunk: AVAudioFrameCount = 32768
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
            try file.read(into: buf, frameCount: chunk)
            if buf.frameLength == 0 { break }
            try WavFormat.convert(conv, input: buf, into: &pcm)
        }
        try WavFormat.convert(conv, input: nil, into: &pcm)
        return WavFormat.wav(fromPCM: pcm)
    }
}
