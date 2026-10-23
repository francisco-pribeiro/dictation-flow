import io
import wave

from dictflow import server


def _wav(seconds, sr=16000):
    b = io.BytesIO()
    with wave.open(b, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"\0\0" * int(sr * seconds))
    return b.getvalue()


def test_wav_seconds():
    assert server.wav_seconds(_wav(1.5)) == 1.5
    assert server.wav_seconds(b"junk") == 0.0


def test_timing_suffix_has_no_text():
    res = {"text": "segredo", "raw": "segredo cru", "fell_back": True,
           "timings_ms": {"decode": 5, "asr": 200, "cleanup": 300, "total": 510}}
    line = server.timing_suffix(2.0, res)
    assert line == " decode=5ms asr=200ms cleanup=300ms total=510ms audio=2.0s chars=7 fell_back=true"
    assert "segredo" not in line


class _Eng:
    name = "fake"

    def __init__(self):
        self.calls = 0

    def transcribe(self, samples, sr, lang="auto", prompt=""):
        self.calls += 1
        return "", None


def _worker(engine):
    w = server.Worker.__new__(server.Worker)
    w.engine, w.lock, w.last_warm = engine, server.threading.Lock(), float("-inf")
    return w


def test_warm_rate_limited_and_skips_busy_or_api():
    w = _worker(_Eng())
    assert w.warm() is True
    assert w.warm() is False  # inside the gap
    assert w.engine.calls == 1
    w.last_warm = float("-inf")
    with w.lock:  # a real transcribe is running
        assert w.warm() is False
    g = _worker(_Eng())
    g.engine.name = "groq"
    assert g.warm() is False and g.engine.calls == 0
