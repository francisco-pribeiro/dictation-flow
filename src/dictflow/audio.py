import subprocess

import numpy as np

SR = 16000


def load_audio(path, fmt=None):
    """Decode a file to float32 mono 16 kHz via ffmpeg. `fmt` forces the demuxer (e.g. "wav")."""
    cmd = ["ffmpeg", "-v", "error", "-nostdin", *(["-f", fmt] if fmt else []), "-i", str(path),
           "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"]
    try:
        p = subprocess.run(cmd, capture_output=True)
    except FileNotFoundError:
        raise RuntimeError("ffmpeg not found (brew install ffmpeg)")
    if p.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {p.stderr.decode(errors='replace').strip()}")
    return np.frombuffer(p.stdout, dtype=np.float32)


def _speech_frames(x, sr, threshold, frame_ms):
    """Voiced = RMS above max(threshold, 10% of the 95th-percentile frame RMS), so quiet speech survives."""
    n = int(sr * frame_ms / 1000)
    count = len(x) // n
    if count == 0:
        return n, np.zeros(0, dtype=bool)
    frames = x[: count * n].reshape(count, n)
    rms = np.sqrt((frames.astype(np.float64) ** 2).mean(axis=1))
    return n, rms > max(threshold, 0.1 * np.percentile(rms, 95))


def has_speech(x, sr=SR, threshold=0.002, frame_ms=30):
    return bool(_speech_frames(x, sr, threshold, frame_ms)[1].any())


def trim_silence(x, sr=SR, threshold=0.002, frame_ms=30, pad_ms=300):
    """Trim leading/trailing frames below the RMS threshold, keeping padding.
    Returns an empty array if there is no speech."""
    n, voiced = _speech_frames(x, sr, threshold, frame_ms)
    idx = np.flatnonzero(voiced)
    if idx.size == 0:
        return x[:0]
    pad = int(sr * pad_ms / 1000)
    start = max(0, idx[0] * n - pad)
    end = min(len(x), (idx[-1] + 1) * n + pad)
    return x[start:end]
